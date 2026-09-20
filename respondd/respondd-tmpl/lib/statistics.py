#!/usr/bin/env python3

import json
import logging
import os
import socket

from lib.batadv_netlink import (
    BATADV_CMD_GET_GATEWAYS,
    BATADV_CMD_GET_TRANSTABLE_LOCAL,
    BATADV_TT_CLIENT_NOPURGE,
    BATADV_TT_CLIENT_ROAM,
    BATADV_TT_CLIENT_WIFI,
)
from lib.respondd import Respondd
import lib.helper

log = logging.getLogger(__name__)

CLIENT_MAX_INACTIVITY_MSECS = 60_000


class Statistics(Respondd):
    def __init__(self, config, batadv_nl=None):
        Respondd.__init__(self, config, batadv_nl)

    def getClients(self):
        ret = {"total": 0, "wifi": 0}

        macBridge = lib.helper.getInterfaceMAC(self._config["bridge"])

        mesh_idx = self._mesh_idx()
        if mesh_idx is None:
            return ret

        for reply in self._get_batadv().dump(BATADV_CMD_GET_TRANSTABLE_LOCAL, mesh_idx):
            attrs = dict(reply["attrs"])
            mac = attrs.get("BATADV_ATTR_TT_ADDRESS")
            flags = attrs.get("BATADV_ATTR_TT_FLAGS", 0)
            if mac is None:
                continue
            mac = mac.lower()
            if mac == macBridge:
                continue
            if flags & BATADV_TT_CLIENT_ROAM:
                continue
            # NOPURGE marks non-ageing service entries (own node, bridge
            # loop avoidance, …); counting them inflates clients.total.
            # See gluon-mesh-batman-adv's respondd-statistics.c.
            if flags & BATADV_TT_CLIENT_NOPURGE:
                continue
            lastseen = attrs.get("BATADV_ATTR_LAST_SEEN_MSECS")
            if lastseen is None or lastseen > CLIENT_MAX_INACTIVITY_MSECS:
                continue
            if mac.startswith("33:33:") or mac.startswith("01:00:5e:"):
                continue
            ret["total"] += 1
            if flags & BATADV_TT_CLIENT_WIFI:
                ret["wifi"] += 1

        return ret

    def getTraffic(self):
        traffic = {}
        lines = lib.helper.call(["ethtool", "-S", self._config["batman"]])
        if len(lines) == 0:
            return {}
        for line in lines[1:]:
            lineSplit = line.strip().split(":", 1)
            name = lineSplit[0]
            value = lineSplit[1].strip()
            traffic[name] = int(value)

        ret = {
            "tx": {
                "packets": traffic["tx"],
                "bytes": traffic["tx_bytes"],
                "dropped": traffic["tx_dropped"],
            },
            "rx": {
                "packets": traffic["rx"],
                "bytes": traffic["rx_bytes"],
            },
            "forward": {
                "packets": traffic["forward"],
                "bytes": traffic["forward_bytes"],
            },
            "mgmt_rx": {
                "packets": traffic["mgmt_rx"],
                "bytes": traffic["mgmt_rx_bytes"],
            },
            "mgmt_tx": {
                "packets": traffic["mgmt_tx"],
                "bytes": traffic["mgmt_tx_bytes"],
            },
        }

        return ret

    @staticmethod
    def getMemory():
        ret = {}
        lines = open("/proc/meminfo").readlines()
        for line in lines:
            lineSplit = line.split(" ", 1)
            name = lineSplit[0][:-1]
            value = int(lineSplit[1].strip().split(" ", 1)[0])

            if name == "MemTotal":
                ret["total"] = value
            elif name == "MemFree":
                ret["free"] = value
            elif name == "Buffers":
                ret["buffers"] = value
            elif name == "Cached":
                ret["cached"] = value

        return ret

    def getFastd(self):
        dataFastd = b""

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(self._config["fastd_socket"])
        except socket.error as err:
            log.warning("fastd socket error: %s", err)
            return None

        while True:
            data = sock.recv(1024)
            if not data:
                break
            dataFastd += data

        sock.close()
        return json.loads(dataFastd.decode("utf-8"))

    def getMeshVPNPeers(self):
        ret = {}

        if "fastd_socket" in self._config:
            fastd = self.getFastd()
            for peer in fastd["peers"].values():
                if peer["connection"]:
                    ret[peer["name"]] = {
                        "established": peer["connection"]["established"]
                    }
                else:
                    ret[peer["name"]] = None

            return ret
        else:
            return None

    def getGateway(self):
        mesh_idx = self._mesh_idx()
        if mesh_idx is None:
            return None

        for reply in self._get_batadv().dump(BATADV_CMD_GET_GATEWAYS, mesh_idx):
            attrs = dict(reply["attrs"])
            if not attrs.get("BATADV_ATTR_FLAG_BEST"):
                continue
            orig = attrs.get("BATADV_ATTR_ORIG_ADDRESS")
            router = attrs.get("BATADV_ATTR_ROUTER")
            if orig is None or router is None:
                continue
            return {"gateway": orig.lower(), "gateway_nexthop": router.lower()}

        return None

    @staticmethod
    def getRootFS():
        statFS = os.statvfs("/")
        return 1 - (statFS.f_bfree / statFS.f_blocks)

    def _get(self):
        ret = {
            "clients": self.getClients(),
            "traffic": self.getTraffic(),
            "memory": self.getMemory(),
            "rootfs_usage": round(self.getRootFS(), 4),
            "idletime": float(open("/proc/uptime").read().split(" ")[1]),
            "uptime": float(open("/proc/uptime").read().split(" ")[0]),
            "loadavg": float(open("/proc/loadavg").read().split(" ")[0]),
            "processes": dict(
                zip(
                    ("running", "total"),
                    map(int, open("/proc/loadavg").read().split(" ")[3].split("/")),
                )
            ),
            "mesh_vpn": {  # HopGlass-Server: node.flags.uplink = parsePeerGroup(_.get(n, 'statistics.mesh_vpn'))
                "groups": {"backbone": {"peers": self.getMeshVPNPeers()}}
            },
        }

        gateway = self.getGateway()
        if gateway is not None:
            ret = lib.helper.merge(ret, gateway)

        return ret
