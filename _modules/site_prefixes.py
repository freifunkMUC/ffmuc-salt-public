#!/usr/bin/python
"""Look up IPAM prefixes in Netbox.

This module is called at Jinja render time by dhcp-server/dhcpd.conf,
wireguard/wg.jinja2 and knot-resolver/kresd.override.socket. Those templates
render *network service configuration*, so a failed lookup must never be
turned into "no prefixes": dhcpd.conf would then render without any subnet,
get written, and restart isc-dhcp-server into a config that hands out no
leases at all - while Salt reports success. Fail closed instead, so the
render aborts, the old config stays in place and the highstate goes red.
"""

import logging

import requests
from salt.exceptions import CommandExecutionError

log = logging.getLogger(__name__)

# Netbox is a hard dependency of the render; bound it so a hanging API
# cannot stall the whole highstate. (connect, read)
REQUEST_TIMEOUT = (5, 30)


def get_site_prefixes(netbox_api, netbox_token, filter):
    headers = {"Authorization": "Token {}".format(netbox_token)}
    url = netbox_api + "/ipam/prefixes/?" + filter
    prefixes = {}
    try:
        response = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()
        results = response.json()["results"]
    except Exception as exc:
        raise CommandExecutionError(
            "site_prefixes: querying Netbox for prefixes failed ({}): {}".format(
                url, exc
            )
        )

    for prefix in results:
        prefixes[prefix["description"]] = prefix
    return prefixes
