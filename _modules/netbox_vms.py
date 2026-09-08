#!/usr/bin/python
"""WIP module to get virtual machine data from netbox, e.g. to get all VMs with a certain tag.."""

import logging

import requests
from salt.exceptions import CommandExecutionError

log = logging.getLogger(__name__)

# (connect, read) - bound the call so a hanging Netbox cannot stall a render.
REQUEST_TIMEOUT = (5, 30)


def get_vms_by_filter(netbox_api, netbox_token, filter):
    # Example filter: 'tag=authorative-dns'
    headers = {
        "Authorization": "Token {}".format(netbox_token),
        "Accept": "application/json",
    }
    url = f"{netbox_api}/virtualization/virtual-machines/?{filter}"
    try:
        response = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()
        results = response.json()["results"]
    except Exception as exc:
        raise CommandExecutionError(
            "netbox_vms: querying Netbox for virtual machines failed ({}): {}".format(
                url, exc
            )
        )

    return [vm["name"] for vm in results]
