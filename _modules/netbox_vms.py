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


def _get(netbox_api, headers, path):
    url = f"{netbox_api}/{path}"
    try:
        response = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()
        return response.json()
    except Exception as exc:
        raise CommandExecutionError(
            "netbox_vms: querying Netbox failed ({}): {}".format(url, exc)
        )


def get_vm_install_data(netbox_api, netbox_token, name):
    """Data for an unattended install of one VM: interfaces with MAC and addresses.

    Returns {"name", "primary_ip4", "interfaces": [{"name", "mac", "addresses"}]}.
    """
    headers = {
        "Authorization": "Token {}".format(netbox_token),
        "Accept": "application/json",
    }
    vms = _get(netbox_api, headers, f"virtualization/virtual-machines/?name={name}")[
        "results"
    ]
    if len(vms) != 1:
        raise CommandExecutionError(
            "netbox_vms: expected one VM named {}, found {}".format(name, len(vms))
        )
    vm = vms[0]
    addresses = {}
    for ip in _get(
        netbox_api, headers, f"ipam/ip-addresses/?virtual_machine_id={vm['id']}&limit=0"
    )["results"]:
        if ip.get("assigned_object_id") is not None:
            addresses.setdefault(ip["assigned_object_id"], []).append(ip["address"])
    interfaces = []
    for iface in _get(
        netbox_api,
        headers,
        f"virtualization/interfaces/?virtual_machine_id={vm['id']}&limit=0",
    )["results"]:
        # NetBox >= 4.2 keeps the MAC in primary_mac_address, mac_address is the old field
        mac = (iface.get("primary_mac_address") or {}).get("mac_address") or iface.get(
            "mac_address"
        )
        interfaces.append(
            {
                "name": iface["name"],
                "mac": mac.lower() if mac else None,
                "addresses": sorted(addresses.get(iface["id"], [])),
            }
        )
    return {
        "name": vm["name"],
        "primary_ip4": (vm.get("primary_ip4") or {}).get("address"),
        "interfaces": sorted(interfaces, key=lambda i: i["name"]),
    }
