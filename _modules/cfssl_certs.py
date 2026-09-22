#!/usr/bin/python
#
# Annika Wickert <aw@awlnx.space>
#  --  Wed 03 April 2019
#
__virtualname__ = "cfssl_certs"
import json
import logging

log = logging.getLogger(__name__)

try:
    import requests

    IMPORT_WORKED = True
except ImportError:
    IMPORT_WORKED = False

# The CA is contacted while certs/init.sls is being rendered, so a hanging CA
# would stall the whole highstate. Always bound the request.
REQUEST_TIMEOUT = (5, 30)


def __virtual__():
    if IMPORT_WORKED:
        return "cfssl_certs"
    else:
        return (
            False,
            "The cfssl_certs execution module cannot be loaded: requests unavailable.",
        )


def request_cert(ca_url, certname):
    cert_req = json.dumps(
        {
            "request": {
                "CN": certname,
                "hosts": [certname],
                "key": {"algo": "rsa", "size": 2048},
                "names": [{"C": "DE", "ST": "Bavaria", "L": "Munich", "O": "FFMUC"}],
            }
        }
    )
    headers = {"Content-type": "application/json"}
    try:
        r = requests.post(
            ca_url + "/api/v1/cfssl/newcert",
            data=cert_req,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
        )
        r.raise_for_status()
        cert_bundle = r.json()
        return cert_bundle["result"]
    except Exception as exc:
        log.error("cfssl_certs: requesting cert for %s failed: %s", certname, exc)
        return False
