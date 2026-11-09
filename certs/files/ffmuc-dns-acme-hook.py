#!/opt/certbot-venv/bin/python3
"""
certbot --manual hook for the DDR certificate "ffmuc-dns" (managed by Salt, certs/init.sls).

One order mixes two challenge types (certbot --preferred-challenges dns,http):

* DNS names get DNS-01: TXT record in the ffmuc.net zone via the Gcore API
  (same token as the ffmuc.net wildcard certificate).
* IP addresses get HTTP-01 (DNS-01 is not possible for IPs, RFC 8738): the key
  authorization goes into the haproxy peers table meet/acme. The table syncs to
  all webfrontends, so the node that gets the anycast request answers it
  (haproxy/haproxy.cfg, frontend http-in).

Usage: ffmuc-dns-acme-hook.py auth|cleanup  (environment from certbot)
       ffmuc-dns-acme-hook.py covers <fullchain.pem> <seconds> <identifier>...
           exit 0 if the certificate is valid for more than <seconds> and its
           SANs are exactly the identifiers (Salt "unless" check)
"""

import datetime
import http.client
import ipaddress
import os
import re
import socket
import sys
import time

HAPROXY_SOCKET = "/run/haproxy/admin.sock"
ACME_TABLE = "meet/acme"
GCORE_CREDENTIALS = "/var/lib/cache/salt/dns_gcore_credentials.ini"
GCORE_ZONE = "ffmuc.net"
TXT_TTL = 120
# Same wait as --dns-gcore-propagation-seconds of the ffmuc.net certificate
DNS_PROPAGATION_SECONDS = 80
# Peers push updates at once; this only covers a short nebula hiccup
PEER_SYNC_SECONDS = 5

KEY_AUTHORIZATION = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")


def log(message):
    print(message, file=sys.stderr)


def is_ip(identifier):
    try:
        ipaddress.ip_address(identifier)
    except ValueError:
        return False
    return True


def haproxy_command(command, path=HAPROXY_SOCKET):
    """Run one command on the haproxy runtime API; output means an error."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(path)
        sock.sendall(command.encode("ascii") + b"\n")
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    output = b"".join(chunks).decode("utf-8", "replace").strip()
    if output:
        raise RuntimeError("haproxy: {!r} failed: {}".format(command, output))


def check_local_responder(identifier, token, validation, port=80):
    """Fail early (before Let's Encrypt validates) if haproxy does not answer."""
    host = "[{}]".format(identifier) if ":" in identifier else identifier
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(
            "GET",
            "/.well-known/acme-challenge/{}".format(token),
            headers={"Host": host},
        )
        response = connection.getresponse()
        body = response.read().decode("utf-8", "replace").strip()
    finally:
        connection.close()
    if response.status != 200 or body != validation:
        raise RuntimeError(
            "local haproxy does not answer the HTTP-01 challenge for {} "
            "(status {}). Is this node's ACME account thumbprint rendered into "
            "haproxy.cfg (Salt mine acme_thumbprints)?".format(
                identifier, response.status
            )
        )


def gcore_client():
    # Only needed for DNS-01, installed with certbot-dns-gcore (certs/init.sls)
    from certbot_dns_gcore.api_gcore import GCoreClient

    token = None
    with open(GCORE_CREDENTIALS, encoding="utf-8") as handle:
        for line in handle:
            key, _, value = line.partition("=")
            if key.strip() == "dns_gcore_apitoken":
                token = value.strip()
    if not token:
        raise RuntimeError("no dns_gcore_apitoken in {}".format(GCORE_CREDENTIALS))
    return GCoreClient(token=token)


def txt_data(values):
    return {
        "resource_records": [{"content": [value], "enabled": True} for value in values],
        "ttl": TXT_TTL,
    }


def dns_record_name(identifier):
    if identifier != GCORE_ZONE and not identifier.endswith("." + GCORE_ZONE):
        raise RuntimeError("{} is not in zone {}".format(identifier, GCORE_ZONE))
    return "_acme-challenge." + identifier


def dns_add(client, identifier, validation):
    from certbot_dns_gcore.api_gcore import GCoreConflictException

    name = dns_record_name(identifier)
    try:
        client.record_create(GCORE_ZONE, name, "TXT", data=txt_data([validation]))
    except GCoreConflictException:
        # Other webfrontends can validate the same name at the same time: append, never replace
        values = client.record_content(GCORE_ZONE, name, "TXT")
        if validation not in values:
            values.append(validation)
        client.record_update(GCORE_ZONE, name, "TXT", data=txt_data(values))


def dns_remove(client, identifier, validation):
    from certbot_dns_gcore.api_gcore import GCoreNotFoundException

    name = dns_record_name(identifier)
    try:
        values = client.record_content(GCORE_ZONE, name, "TXT")
    except GCoreNotFoundException:
        return
    remaining = [value for value in values if value != validation]
    if remaining:
        client.record_update(GCORE_ZONE, name, "TXT", data=txt_data(remaining))
    else:
        client.record_delete(GCORE_ZONE, name, "TXT")


def wait_seconds(all_identifiers):
    """Seconds to wait after the last challenge before certbot asks for validation."""
    if any(not is_ip(identifier) for identifier in all_identifiers):
        return DNS_PROPAGATION_SECONDS
    return PEER_SYNC_SECONDS


def auth(env):
    identifier = env["CERTBOT_DOMAIN"]
    validation = env["CERTBOT_VALIDATION"]
    token = env.get("CERTBOT_TOKEN")
    if token:
        if not KEY_AUTHORIZATION.match(validation) or not validation.startswith(
            token + "."
        ):
            raise RuntimeError("unexpected HTTP-01 key authorization")
        haproxy_command(
            "set table {} key {} data.gpt0 1".format(ACME_TABLE, validation)
        )
        check_local_responder(identifier, token, validation)
        log("HTTP-01 {}: key authorization in {}".format(identifier, ACME_TABLE))
    else:
        dns_add(gcore_client(), identifier, validation)
        log("DNS-01 {}: TXT record added".format(identifier))

    if env.get("CERTBOT_REMAINING_CHALLENGES", "0") == "0":
        all_identifiers = env.get("CERTBOT_ALL_DOMAINS", identifier).split(",")
        time.sleep(wait_seconds(all_identifiers))


def cleanup(env):
    identifier = env["CERTBOT_DOMAIN"]
    validation = env["CERTBOT_VALIDATION"]
    if env.get("CERTBOT_TOKEN"):
        # Only clears the local entry (peers do not sync deletes); the others expire after 10m
        if KEY_AUTHORIZATION.match(validation):
            haproxy_command("clear table {} key {}".format(ACME_TABLE, validation))
    else:
        dns_remove(gcore_client(), identifier, validation)


def normalize_identifier(identifier):
    if is_ip(identifier):
        return str(ipaddress.ip_address(identifier))
    return identifier.lower()


def covers(cert_path, min_seconds, identifiers, now=None):
    """True if the certificate is valid for more than min_seconds and has exactly these SANs."""
    from cryptography import x509

    with open(cert_path, "rb") as handle:
        cert = x509.load_pem_x509_certificate(handle.read())
    not_after = getattr(
        cert, "not_valid_after_utc", None
    ) or cert.not_valid_after.replace(tzinfo=datetime.timezone.utc)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if (not_after - now).total_seconds() <= min_seconds:
        return False
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    have = {name.lower() for name in san.get_values_for_type(x509.DNSName)}
    have |= {str(address) for address in san.get_values_for_type(x509.IPAddress)}
    return have == {normalize_identifier(identifier) for identifier in identifiers}


def main(argv, env):
    if len(argv) >= 4 and argv[1] == "covers":
        try:
            return 0 if covers(argv[2], int(argv[3]), argv[4:]) else 1
        except (OSError, ValueError) as error:
            log("covers: {}".format(error))
            return 1
    if len(argv) != 2 or argv[1] not in ("auth", "cleanup"):
        log("usage: {} auth|cleanup|covers".format(argv[0]))
        return 2
    try:
        (auth if argv[1] == "auth" else cleanup)(env)
    except Exception as error:  # pylint: disable=broad-except
        log("{} {}: {}".format(argv[1], env.get("CERTBOT_DOMAIN"), error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv, os.environ))
