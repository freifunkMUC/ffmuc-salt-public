"""
Dynamic DNS state, wrapping the ddns execution module in ``_modules/ddns.py``.

Vendored because Salt 3008 no longer ships the ``ddns`` state.
"""


def __virtual__():
    if "ddns.update" in __salt__:
        return "ddns"
    return (False, "ddns state module could not be loaded: ddns module unavailable")


def present(name, zone, ttl, data, rdtype="A", **kwargs):
    """
    Ensure that the named DNS record is present with the given ttl.

    name
        The host portion of the DNS record, e.g., 'webserver'. Name and zone
        are concatenated when the entry is created unless name includes a
        trailing dot, so make sure that information is not duplicated in
        these two arguments.

    zone
        The zone to check/update

    ttl
        TTL for the record

    data
        Data for the DNS record. E.g., the IP address for an A record.

    rdtype
        DNS resource type. Default 'A'.

    ``**kwargs``
        Additional arguments the ddns.update function may need (e.g.
        nameserver, keyfile, keyname, port, replace_on_change).
    """
    ret = {"name": name, "changes": {}, "result": False, "comment": ""}

    if __opts__["test"]:
        ret["result"] = None
        ret["comment"] = '{} record "{}" will be updated'.format(rdtype, name)
        return ret

    status = __salt__["ddns.update"](zone, name, ttl, rdtype, data, **kwargs)

    if status is None:
        ret["result"] = True
        ret["comment"] = '{} record "{}" already present with ttl of {}'.format(
            rdtype, name, ttl
        )
    elif status:
        ret["result"] = True
        ret["comment"] = 'Updated {} record for "{}"'.format(rdtype, name)
        ret["changes"] = {
            "name": name,
            "zone": zone,
            "ttl": ttl,
            "rdtype": rdtype,
            "data": data,
        }
    else:
        ret["comment"] = 'Failed to create or update {} record for "{}"'.format(
            rdtype, name
        )
    return ret


def absent(name, zone, data=None, rdtype=None, **kwargs):
    """
    Ensure that the named DNS record is absent.

    name
        The host portion of the DNS record, e.g., 'webserver'. Name and zone
        are concatenated when the entry is created unless name includes a
        trailing dot, so make sure that information is not duplicated in
        these two arguments.

    zone
        The zone to check

    data
        Data for the DNS record. E.g., the IP address for an A record. If
        omitted, all records matching name (and rdtype, if provided) will be
        purged.

    rdtype
        DNS resource type. If omitted, all types will be purged.

    ``**kwargs``
        Additional arguments the ddns.delete function may need (e.g.
        nameserver, keyfile, keyname, port).
    """
    ret = {"name": name, "changes": {}, "result": False, "comment": ""}

    if __opts__["test"]:
        ret["result"] = None
        ret["comment"] = '{} record "{}" will be deleted'.format(rdtype, name)
        return ret

    status = __salt__["ddns.delete"](zone, name, rdtype, data, **kwargs)

    if status is None:
        ret["result"] = True
        ret["comment"] = "No matching DNS record(s) present"
    elif status:
        ret["result"] = True
        ret["comment"] = "Deleted DNS record(s)"
        ret["changes"] = {"Deleted": {"name": name, "zone": zone}}
    else:
        ret["comment"] = "Failed to delete DNS record(s)"
    return ret
