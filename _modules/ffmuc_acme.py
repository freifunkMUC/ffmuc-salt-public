"""
ACME account thumbprints (RFC 7638) of the local certbot accounts.

Published through the Salt mine as ``acme_thumbprints`` (see certs/init.sls).
haproxy on every webfrontend uses them to answer HTTP-01 challenges for the
DDR certificate (``ffmuc-dns``) of any webfrontend; see haproxy/haproxy.cfg.

The thumbprint is derived from the public part of the account key only, it is
not secret (it is part of every HTTP-01 key authorization).
"""

import base64
import glob
import hashlib
import json
import os

# Members of the public key per key type, RFC 7638 section 3.2
_REQUIRED_MEMBERS = {
    "RSA": ("e", "kty", "n"),
    "EC": ("crv", "kty", "x", "y"),
    "OKP": ("crv", "kty", "x"),
}


def jwk_thumbprint(jwk):
    """
    Return the RFC 7638 SHA-256 thumbprint (base64url, no padding) of a JWK.

    Private members (e.g. ``d``) are ignored.

    CLI Example:

    .. code-block:: bash

        salt '*' ffmuc_acme.jwk_thumbprint '{"kty": "RSA", "e": "AQAB", "n": "..."}'
    """
    if isinstance(jwk, str):
        jwk = json.loads(jwk)
    members = _REQUIRED_MEMBERS.get(jwk.get("kty"))
    if members is None:
        raise ValueError("unsupported JWK key type: {}".format(jwk.get("kty")))
    public = {member: jwk[member] for member in members}
    canonical = json.dumps(public, separators=(",", ":"), sort_keys=True)
    digest = hashlib.sha256(canonical.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def account_thumbprints(config_dir="/etc/letsencrypt"):
    """
    Return the sorted thumbprints of all certbot ACME accounts on this host,
    for all ACME servers (production and staging).

    Unreadable or broken account files are skipped.

    CLI Example:

    .. code-block:: bash

        salt 'webfrontend*' ffmuc_acme.account_thumbprints
    """
    pattern = os.path.join(config_dir, "accounts", "*", "*", "*", "private_key.json")
    thumbprints = set()
    for path in glob.glob(pattern):
        try:
            with open(path, encoding="utf-8") as handle:
                thumbprints.add(jwk_thumbprint(json.load(handle)))
        except (OSError, ValueError, KeyError):
            continue
    return sorted(thumbprints)
