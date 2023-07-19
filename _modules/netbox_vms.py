#!/usr/bin/python
"""WIP module to get virtual machine data from netbox, e.g. to get all VMs with a certain tag..
"""

import requests
import logging

log = logging.getLogger(__name__)


def get_vms_by_filter(netbox_api, netbox_token, filter):
    # Example filter: 'tag=authorative-dns'
    headers = {
        "Authorization": "Token {}".format(netbox_token),
        "Accept": "application/json",
    }
    url = f"{netbox_api}/virtualization/virtual-machines/?{filter}"
    auth_servers = []
    try:
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        response = response.json()
        log.info(response)
        for auth in response["results"]:
            auth_servers.append(auth["name"])
    except Exception as e:
        log.error(str(e))
        __context__["retcode"] = 1
        return e
    return auth_servers
