"""
Reverse DNS helpers for the FFMUC public prefixes.
"""

import ipaddress


def _fqdn(name):
    name = str(name).strip()
    return name if name.endswith(".") else name + "."


def _zone_for(address, networks):
    matches = [(network, zone) for network, zone in networks if address in network]
    if not matches:
        return None
    return max(matches, key=lambda match: match[0].prefixlen)[1]


def ptr_records(candidates, zones, custom=None):
    """
    Build PTR records for addresses inside the configured reverse zones.

    ``candidates`` is a list of ``{'address', 'target', 'priority'}`` dicts,
    usually derived from A/AAAA records; for duplicate addresses the lowest
    priority wins. ``zones`` maps prefixes to reverse zone names. ``custom``
    maps a PTR target to one or more addresses and overrides candidates.
    """
    networks = [
        (ipaddress.ip_network(prefix), zone.rstrip("."))
        for prefix, zone in (zones or {}).items()
    ]
    selected = {}

    for candidate in sorted(
        candidates or [],
        key=lambda c: (c.get("priority", 100), _fqdn(c["target"])),
    ):
        try:
            address = ipaddress.ip_address(str(candidate["address"]).split("/")[0])
        except ValueError:
            continue
        selected.setdefault(address, _fqdn(candidate["target"]))

    for target, addresses in (custom or {}).items():
        if isinstance(addresses, str):
            addresses = [addresses]
        for address in addresses:
            selected[ipaddress.ip_address(str(address))] = _fqdn(target)

    records = []
    for address, target in selected.items():
        zone = _zone_for(address, networks)
        if zone:
            records.append(
                {
                    "address": str(address),
                    "name": address.reverse_pointer + ".",
                    "zone": zone,
                    "target": target,
                }
            )
    return sorted(
        records,
        key=lambda r: (
            ipaddress.ip_address(r["address"]).version,
            ipaddress.ip_address(r["address"]),
        ),
    )
