#!/usr/bin/env python3

import logging
import socket

from lib.batadv_netlink import (
    BATADV_CMD_GET_NEIGHBORS,
    list_hard_interfaces,
    missing_attrs,
)
from lib.respondd import Respondd

log = logging.getLogger(__name__)

# Skip rows missing any of these (mirrors gluon-mesh-batman-adv's
# respondd-neighbours.c). Without it, throughput=0 leaks through and
# meshviewer renders the link as a dead edge.
NEIGH_MANDATORY = (
    "BATADV_ATTR_NEIGH_ADDRESS",
    "BATADV_ATTR_THROUGHPUT",
    "BATADV_ATTR_HARD_IFINDEX",
    "BATADV_ATTR_LAST_SEEN_MSECS",
)


class Neighbours(Respondd):
    def __init__(self, config, batadv_nl=None):
        Respondd.__init__(self, config, batadv_nl)

    def _get(self):
        ret = {"batadv": {}}

        mesh_idx = self._mesh_idx()
        if mesh_idx is None:
            return ret

        batadv = self._get_batadv()
        meshInterfaces = list_hard_interfaces(batadv, mesh_idx)
        replies = batadv.dump(BATADV_CMD_GET_NEIGHBORS, mesh_idx)

        for reply in replies:
            attrs = dict(reply["attrs"])
            if missing_attrs(attrs, NEIGH_MANDATORY):
                continue
            try:
                ifname = socket.if_indextoname(attrs["BATADV_ATTR_HARD_IFINDEX"])
            except OSError:
                continue
            if ifname not in meshInterfaces:
                continue
            neighMac = attrs["BATADV_ATTR_NEIGH_ADDRESS"].lower()
            if meshInterfaces[ifname] not in ret["batadv"]:
                ret["batadv"][meshInterfaces[ifname]] = {"neighbours": {}}
            ret["batadv"][meshInterfaces[ifname]]["neighbours"][neighMac] = {
                "throughput": attrs["BATADV_ATTR_THROUGHPUT"],
                "lastseen": attrs["BATADV_ATTR_LAST_SEEN_MSECS"] / 1000.0,
                # Kernel doesn't set FLAG_BEST on GET_NEIGHBORS replies, so
                # this is always False — emitted for schema parity with
                # yanic/meshviewer.
                "best": bool(attrs.get("BATADV_ATTR_FLAG_BEST")),
            }

        return ret
