#!/usr/bin/env python3
"""Wazuh integratord -> Matrix room. Called as: custom-matrix <alert.json> [api_key] [hook_url] ...

The room's send endpoint (without transaction id) and the bot's access token are the two lines of
/var/ossec/etc/matrix-hook, written at container start from the stack secrets.
"""

import json
import sys
import time
import urllib.parse
import urllib.request

HOOK_FILE = "/var/ossec/etc/matrix-hook"


def main():
    with open(sys.argv[1]) as fh:
        alert = json.load(fh)
    with open(HOOK_FILE) as fh:
        url, token = fh.read().split("\n")[:2]
    rule = alert.get("rule", {})
    agent = alert.get("agent", {})
    text = "Wazuh level {} on {}: {} (rule {})".format(
        rule.get("level", "?"),
        agent.get("name", "manager"),
        rule.get("description", "no description"),
        rule.get("id", "?"),
    )
    body = json.dumps({"msgtype": "m.notice", "body": text}).encode()
    txn = "wazuh-{}-{}".format(
        alert.get("id", int(time.time() * 1000)), rule.get("id", "0")
    )
    req = urllib.request.Request(
        "{}/{}".format(url.rstrip("/"), urllib.parse.quote(txn, safe="")),
        data=body,
        method="PUT",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # integratord logs stderr; never print the URL or token
        print("custom-matrix: {}".format(type(exc).__name__), file=sys.stderr)
        sys.exit(1)
