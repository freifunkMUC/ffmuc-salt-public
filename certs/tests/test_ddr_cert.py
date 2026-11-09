"""Tests for the DDR certificate "ffmuc-dns" (certs/ddr_cert.jinja).

Synthetic data only, no network, no ACME server.
Run: python3 -m unittest discover -s certs/tests
"""

import datetime
import importlib.util
import ipaddress
import json
import os
import re
import socket
import tempfile
import threading
import unittest
from unittest import mock

import jinja2

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ffmuc_acme = load("ffmuc_acme", "_modules/ffmuc_acme.py")
hook = load("ffmuc_dns_acme_hook", "certs/files/ffmuc-dns-acme-hook.py")

# RFC 7638 section 3.1
RFC7638_JWK = {
    "kty": "RSA",
    "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
    "e": "AQAB",
    "alg": "RS256",
    "kid": "2011-04-29",
}
RFC7638_THUMBPRINT = "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"

NODE = "webfrontend01.in.ffmuc.net"
PEER = "webfrontend02.in.ffmuc.net"
TP_NODE = "A" * 43
TP_PEER = "b-_" + "B" * 40
ANYCAST = ["185.150.99.255", "5.1.66.255", "2001:678:e68:f000::", "2001:678:ed0:f000::"]


class FakeSalt(dict):
    """Minimal salt[...] for the templates (config.get, mine.get, file.file_exists, pillar.get)."""

    def __init__(self, ddr_cert=None, cert_exists=False, thumbprints=None):
        super().__init__()
        config = {
            "netbox:site:name": "MUC01",
            "netbox:tag_list": [],
            "netbox:config_context:haproxy:cluster_secret": "secret",
            "netbox:config_context:ddr_cert": ddr_cert or {},
            "reverse_dns:zones": {},
            "netbox:primary_ip4:address": "10.0.0.1/24",
            "netbox:site:slug": "muc01",
        }
        mine = {
            "minion_id": {NODE: NODE, PEER: PEER},
            "minion_location": {NODE: "MUC01", PEER: "VIE01"},
            "minion_address": {NODE: "10.0.0.1/24", PEER: "10.0.0.2/24"},
            "minion_overlay_address": {NODE: "10.8.0.1/16", PEER: "10.8.0.2/16"},
            "minion_external_ip": {NODE: ["198.51.100.1/32"], PEER: ["198.51.100.2"]},
            "minion_external_ip6": {NODE: ["2001:db8::1/64"], PEER: ["2001:db8::2"]},
            "acme_thumbprints": thumbprints
            or {NODE: [TP_NODE], PEER: [TP_PEER, "bad thumbprint"]},
        }

        def mine_get(tgt, fun, tgt_type="glob"):
            data = mine.get(fun, {})
            if tgt_type == "glob":
                return {tgt: data[tgt]} if tgt in data else {}
            return dict(data)

        self["config.get"] = lambda key, default=None: config.get(key, default)
        self["pillar.get"] = lambda key, default=None: config.get(key, default)
        self["mine.get"] = mine_get
        self["file.file_exists"] = lambda path: cert_exists


def regex_match(value, pattern):
    match = re.match(pattern, value)
    return match.groups() if match else None


def render(path, salt, grains_id=NODE):
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(REPO), extensions=["jinja2.ext.do"]
    )
    env.filters["regex_match"] = regex_match
    env.filters["regex_replace"] = lambda value, pattern, repl: re.sub(
        pattern, repl, value
    )
    grains = {"id": grains_id, "num_cpus": 4}
    return env.get_template(path).render(salt=salt, grains=grains, pillar={})


ALL_ON = {
    "responder": True,
    "issue": True,
    "haproxy": True,
    "dot": True,
    "doq": True,
}


class ThumbprintTest(unittest.TestCase):
    def test_rfc7638_example(self):
        self.assertEqual(ffmuc_acme.jwk_thumbprint(RFC7638_JWK), RFC7638_THUMBPRINT)
        self.assertEqual(
            ffmuc_acme.jwk_thumbprint(json.dumps(RFC7638_JWK)), RFC7638_THUMBPRINT
        )

    def test_private_members_ignored(self):
        jwk = dict(RFC7638_JWK, d="secret", p="secret", q="secret")
        self.assertEqual(ffmuc_acme.jwk_thumbprint(jwk), RFC7638_THUMBPRINT)

    def test_unsupported_key_type(self):
        with self.assertRaises(ValueError):
            ffmuc_acme.jwk_thumbprint({"kty": "oct", "k": "x"})

    def test_account_thumbprints(self):
        with tempfile.TemporaryDirectory() as config_dir:

            def account(server, name, content):
                path = os.path.join(config_dir, "accounts", server, "directory", name)
                os.makedirs(path)
                with open(os.path.join(path, "private_key.json"), "w") as handle:
                    handle.write(content)

            account("acme-v02.api.letsencrypt.org", "a1", json.dumps(RFC7638_JWK))
            account(
                "acme-staging-v02.api.letsencrypt.org",
                "a2",
                json.dumps({"kty": "EC", "crv": "P-256", "x": "x", "y": "y"}),
            )
            account("acme-staging-v02.api.letsencrypt.org", "a3", "{broken")
            result = ffmuc_acme.account_thumbprints(config_dir)
        self.assertEqual(len(result), 2)
        self.assertIn(RFC7638_THUMBPRINT, result)
        self.assertEqual(result, sorted(result))
        for thumbprint in result:
            self.assertRegex(thumbprint, r"^[A-Za-z0-9_-]{43}$")

    def test_no_accounts(self):
        with tempfile.TemporaryDirectory() as config_dir:
            self.assertEqual(ffmuc_acme.account_thumbprints(config_dir), [])


class HaproxyRenderTest(unittest.TestCase):
    def test_off_by_default(self):
        cfg = render("haproxy/haproxy.cfg", FakeSalt(cert_exists=True))
        self.assertNotIn("acme", cfg)
        self.assertNotIn("ffmuc-dns", cfg)

    def test_responder(self):
        cfg = render("haproxy/haproxy.cfg", FakeSalt({"responder": True}))
        self.assertIn(
            "table acme type string len 128 size 1k expire 10m store gpt0", cfg
        )
        host_acl = re.search(r"acl is_acme_ip hdr\(host\) -i (.*)", cfg).group(1)
        self.assertEqual(
            host_acl.split(),
            [
                "185.150.99.255",
                "5.1.66.255",
                "[2001:678:e68:f000::]",
                "[2001:678:ed0:f000::]",
                "198.51.100.1",
                "[2001:db8::1]",
            ],
        )
        returns = re.findall(r"http-request return .*in_table\(meet/acme\).*", cfg)
        self.assertEqual(len(returns), 2)
        self.assertIn('.{}"'.format(TP_NODE), cfg)
        self.assertIn('.{}"'.format(TP_PEER), cfg)
        self.assertNotIn("bad thumbprint", cfg)
        # Before the HTTPS redirects and the ip.ffmuc.net responses
        self.assertLess(cfg.index("is_acme_challenge"), cfg.index("acl is_ip hdr"))
        self.assertLess(cfg.index("is_acme_challenge"), cfg.index("redirect scheme"))
        # Not served before the certificate exists
        self.assertNotIn("ffmuc-dns", cfg.split("crt-store", 1)[1])

    def test_responder_needs_peers(self):
        cfg = render(
            "haproxy/haproxy.cfg",
            FakeSalt({"responder": True}),
            grains_id="webfrontend09.in.ffmuc.net",
        )
        self.assertNotIn("acme", cfg)

    def test_serve(self):
        cfg = render("haproxy/haproxy.cfg", FakeSalt(ALL_ON, cert_exists=True))
        self.assertIn(
            'load crt "ffmuc-dns/fullchain.pem" key "ffmuc-dns/privkey.pem" alias "ffmuc-dns"',
            cfg,
        )
        binds = [line for line in cfg.splitlines() if ":443" in line and "bind" in line]
        self.assertEqual(len(binds), 4)
        for bind in binds:
            self.assertIn(
                'crt "@/ffmuc.net" crt "@/ffmuc-dns" crt "@/ffmuc-cloudflare"', bind
            )

    def test_serve_needs_certificate(self):
        cfg = render("haproxy/haproxy.cfg", FakeSalt(ALL_ON, cert_exists=False))
        self.assertNotIn('"@/ffmuc-dns"', cfg)


class DnsdistRenderTest(unittest.TestCase):
    def test_off_by_default(self):
        cfg = render("dnsdist/dnsdist.conf.j2", FakeSalt(cert_exists=True))
        self.assertNotIn("ddr_", cfg)
        self.assertEqual(cfg.count("ssl_cert, ssl_key"), 12)

    def test_serve(self):
        cfg = render("dnsdist/dnsdist.conf.j2", FakeSalt(ALL_ON, cert_exists=True))
        self.assertIn('ddr_cert="/etc/letsencrypt/live/ffmuc-dns/fullchain.pem"', cfg)
        tls = [line for line in cfg.splitlines() if line.startswith("addTLSLocal")]
        doq = [line for line in cfg.splitlines() if line.startswith("addDOQLocal")]
        self.assertEqual(len(tls), 8)
        self.assertEqual(len(doq), 4)
        for line in tls:
            self.assertIn("{ssl_cert, ddr_cert}, {ssl_key, ddr_key}", line)
        for line in doq:
            self.assertIn("ddr_cert, ddr_key", line)
            self.assertNotIn("ssl_cert", line)

    def test_dot_only(self):
        cfg = render(
            "dnsdist/dnsdist.conf.j2",
            FakeSalt({"responder": True, "dot": True}, cert_exists=True),
        )
        doq = [line for line in cfg.splitlines() if line.startswith("addDOQLocal")]
        for line in doq:
            self.assertIn("ssl_cert, ssl_key", line)

    def test_serve_needs_certificate(self):
        cfg = render("dnsdist/dnsdist.conf.j2", FakeSalt(ALL_ON, cert_exists=False))
        self.assertNotIn("ddr_", cfg)


class CertsStateRenderTest(unittest.TestCase):
    def render_sls(self, ddr_cert):
        salt = FakeSalt(ddr_cert)
        config = {
            "netbox:role:name": "webserver-external",
            "netbox:config_context:gcore:api_token": "token",
        }
        salt["pillar.get"] = lambda key, default=None: config.get(key, default)
        salt["ffmuc_acme.account_thumbprints"] = lambda: [TP_NODE]
        salt["cmd.run"] = lambda cmd: "Certificate will not expire"
        salt["network.ping"] = lambda *args, **kwargs: False
        return render("certs/init.sls", salt)

    def test_off_by_default(self):
        self.assertNotIn("ffmuc-dns-acme", self.render_sls({}))

    def test_issue(self):
        sls = self.render_sls({"responder": True, "issue": True})
        self.assertIn("ffmuc-dns-cert:", sls)
        self.assertIn("--preferred-profile shortlived", sls)
        self.assertIn("--preferred-challenges dns,http", sls)
        for name in ["doh", "dns", "dot", "doq", "anycast", "anycast01", "anycast02"]:
            self.assertIn('-d "{}.ffmuc.net"'.format(name), sls)
        for ip in ANYCAST + ["198.51.100.1", "2001:db8::1"]:
            self.assertIn('--ip-address "{}"'.format(ip), sls)
        issue = sls.split("ffmuc-dns-cert:")[1]
        self.assertNotIn('-d "ffmuc.net"', issue)
        self.assertNotIn('-d "*.ffmuc.net"', issue)
        # Mine is current, so mine.send only runs after a new account
        self.assertIn("onchanges:\n      - cmd: ffmuc-dns-acme-account", sls)
        self.assertIn("ffmuc-dns-staging-cert-absent:", sls)

    def test_staging(self):
        sls = self.render_sls({"responder": True, "staging": True})
        self.assertIn("ffmuc-dns-staging-cert:", sls)
        self.assertIn("--staging", sls.split("ffmuc-dns-staging-cert:")[1])
        self.assertNotIn("ffmuc-dns-cert:", sls)
        self.assertNotIn("staging-cert-absent", sls)

    def test_issue_needs_responder(self):
        sls = self.render_sls({"issue": True})
        self.assertNotIn("ffmuc-dns-acme", sls)


class HookTest(unittest.TestCase):
    def test_usage(self):
        self.assertEqual(hook.main(["hook"], {}), 2)
        self.assertEqual(hook.main(["hook", "renew"], {}), 2)

    def test_wait_seconds(self):
        self.assertEqual(
            hook.wait_seconds(["185.150.99.255", "2001:678:e68:f000::"]), 5
        )
        self.assertEqual(hook.wait_seconds(["185.150.99.255", "dot.ffmuc.net"]), 80)

    def test_dns_record_name(self):
        self.assertEqual(
            hook.dns_record_name("dot.ffmuc.net"), "_acme-challenge.dot.ffmuc.net"
        )
        with self.assertRaises(RuntimeError):
            hook.dns_record_name("dot.example.org")
        with self.assertRaises(RuntimeError):
            hook.dns_record_name("evilffmuc.net")

    def test_http_auth_rejects_bad_key_authorization(self):
        env = {
            "CERTBOT_DOMAIN": "185.150.99.255",
            "CERTBOT_TOKEN": "tok",
            "CERTBOT_VALIDATION": "tok.tp\nclear table meet/acme",
        }
        with mock.patch.object(hook, "haproxy_command") as command:
            self.assertEqual(hook.main(["hook", "auth"], env), 1)
        command.assert_not_called()

    def test_http_auth_and_cleanup(self):
        env = {
            "CERTBOT_DOMAIN": "2001:678:e68:f000::",
            "CERTBOT_TOKEN": "tok",
            "CERTBOT_VALIDATION": "tok." + TP_NODE,
            "CERTBOT_REMAINING_CHALLENGES": "0",
            "CERTBOT_ALL_DOMAINS": "2001:678:e68:f000::,185.150.99.255",
        }
        with mock.patch.object(hook, "haproxy_command") as command, mock.patch.object(
            hook, "check_local_responder"
        ) as check, mock.patch.object(hook.time, "sleep") as sleep:
            self.assertEqual(hook.main(["hook", "auth"], env), 0)
            self.assertEqual(hook.main(["hook", "cleanup"], env), 0)
        self.assertEqual(
            command.call_args_list,
            [
                mock.call("set table meet/acme key tok.{} data.gpt0 1".format(TP_NODE)),
                mock.call("clear table meet/acme key tok.{}".format(TP_NODE)),
            ],
        )
        check.assert_called_once_with("2001:678:e68:f000::", "tok", "tok." + TP_NODE)
        sleep.assert_called_once_with(5)

    def test_haproxy_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "admin.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(2)
            received = []

            def serve():
                for answer in (b"\n", b"Unknown table\n"):
                    conn, _ = server.accept()
                    received.append(conn.recv(4096))
                    conn.sendall(answer)
                    conn.close()

            thread = threading.Thread(target=serve)
            thread.start()
            hook.haproxy_command("set table meet/acme key a.b data.gpt0 1", path)
            with self.assertRaises(RuntimeError):
                hook.haproxy_command("clear table meet/acme key a.b", path)
            thread.join()
            server.close()
        self.assertEqual(received[0], b"set table meet/acme key a.b data.gpt0 1\n")

    def test_dns_add_and_remove(self):
        class Conflict(Exception):
            pass

        class NotFound(Exception):
            pass

        records = {}

        class FakeClient:
            def record_create(self, zone, name, rtype, data):
                if name in records:
                    raise Conflict()
                records[name] = [r["content"][0] for r in data["resource_records"]]

            def record_content(self, zone, name, rtype):
                if name not in records:
                    raise NotFound()
                return list(records[name])

            def record_update(self, zone, name, rtype, data):
                records[name] = [r["content"][0] for r in data["resource_records"]]

            def record_delete(self, zone, name, rtype):
                del records[name]

        module = mock.MagicMock(
            GCoreConflictException=Conflict, GCoreNotFoundException=NotFound
        )
        client = FakeClient()
        name = "_acme-challenge.dot.ffmuc.net"
        with mock.patch.dict(
            "sys.modules",
            {
                "certbot_dns_gcore": mock.MagicMock(),
                "certbot_dns_gcore.api_gcore": module,
            },
        ):
            hook.dns_add(client, "dot.ffmuc.net", "node1")
            hook.dns_add(client, "dot.ffmuc.net", "node2")
            hook.dns_add(client, "dot.ffmuc.net", "node2")
            self.assertEqual(records[name], ["node1", "node2"])
            hook.dns_remove(client, "dot.ffmuc.net", "node1")
            self.assertEqual(records[name], ["node2"])
            hook.dns_remove(client, "dot.ffmuc.net", "node2")
            self.assertNotIn(name, records)
            hook.dns_remove(client, "dot.ffmuc.net", "node2")


try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
except ImportError:  # pragma: no cover
    x509 = None


@unittest.skipIf(x509 is None, "cryptography not installed")
class CoversTest(unittest.TestCase):
    def make_cert(self, names, ips, days):
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.datetime.now(datetime.timezone.utc)
        san = [x509.DNSName(name) for name in names] + [
            x509.IPAddress(ipaddress.ip_address(ip)) for ip in ips
        ]
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test")])
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=days))
            .add_extension(x509.SubjectAlternativeName(san), critical=False)
            .sign(key, hashes.SHA256())
        )
        handle = tempfile.NamedTemporaryFile(suffix=".pem", delete=False)
        handle.write(cert.public_bytes(serialization.Encoding.PEM))
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_covers(self):
        names = ["dot.ffmuc.net", "doh.ffmuc.net"]
        path = self.make_cert(names, ANYCAST, days=6)
        # IPv6 written differently than in the certificate
        wanted = names + ANYCAST[:2] + ["2001:678:e68:f000:0::", "2001:678:ED0:F000::"]
        self.assertEqual(hook.main(["hook", "covers", path, "172800"] + wanted, {}), 0)
        # Expires within the threshold
        self.assertEqual(hook.main(["hook", "covers", path, "604800"] + wanted, {}), 1)
        # Address added or removed
        self.assertEqual(
            hook.main(["hook", "covers", path, "172800"] + wanted + ["192.0.2.1"], {}),
            1,
        )
        self.assertEqual(
            hook.main(["hook", "covers", path, "172800"] + wanted[1:], {}), 1
        )

    def test_missing_file(self):
        self.assertEqual(
            hook.main(["hook", "covers", "/nonexistent.pem", "1", "a.ffmuc.net"], {}),
            1,
        )


if __name__ == "__main__":
    unittest.main()
