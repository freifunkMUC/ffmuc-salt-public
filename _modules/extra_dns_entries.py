#!/usr/bin/python
"""Look up devices in Netbox to generate extra DNS records.

Called at Jinja render time by dns-auth/init.sls. A failed lookup must not
silently degrade to "no extra records" - that would leave the generated zone
data quietly incomplete while the highstate reports success. Fail closed.
"""

import logging

import requests
from salt.exceptions import CommandExecutionError

log = logging.getLogger(__name__)

# (connect, read) - bound the call so a hanging Netbox cannot stall the
# whole highstate at render time.
REQUEST_TIMEOUT = (5, 30)


def get_extra_dns_entries(netbox_api, netbox_token, filter):
    headers = {"Authorization": "Token {}".format(netbox_token)}
    url = netbox_api + "/dcim/devices/?" + filter
    entries = {}
    try:
        response = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()
        results = response.json()["results"]
    except Exception as exc:
        raise CommandExecutionError(
            "extra_dns_entries: querying Netbox for devices failed ({}): {}".format(
                url, exc
            )
        )

    for host in results:
        entries[host["name"]] = {}
        if host["primary_ip4"]:
            entries[host["name"]]["address"] = host["primary_ip4"]["address"].split(
                "/"
            )[0]
        if host["primary_ip6"]:
            entries[host["name"]]["address6"] = host["primary_ip6"]["address"].split(
                "/"
            )[0]
    return entries
