#!/usr/bin/env python3

import logging
import re
import socket

import netifaces as netif

from lib.batadv_netlink import (
    BATADV_CMD_GET_MESH,
    BATADV_GW_MODE_SERVER,
    list_hard_interfaces,
)
from lib.respondd import Respondd
import lib.helper

log = logging.getLogger(__name__)


class Nodeinfo(Respondd):
    def __init__(self, config, batadv_nl=None):
        Respondd.__init__(self, config, batadv_nl)

    @staticmethod
    def getInterfaceAddresses(interface):
        addresses = []

        try:
            for ip6 in netif.ifaddresses(interface)[netif.AF_INET6]:
                addresses.append(ip6["addr"].split("%")[0])

            for ip in netif.ifaddresses(interface)[netif.AF_INET]:
                addresses.append(ip["addr"].split("%")[0])
        except (ValueError, KeyError):
            pass

        return addresses

    def getBatmanInterfaces(self):
        ret = {}

        mesh_idx = self._mesh_idx()
        if mesh_idx is None:
            return ret

        for interface, mac in list_hard_interfaces(
            self._get_batadv(), mesh_idx
        ).items():
            interfaceType = ""
            if (
                "fastd" in self._config and interface == self._config["fastd"]
            ):  # keep for compatibility
                interfaceType = "tunnel"
            elif interface.find("l2tp") != -1:
                interfaceType = "l2tp"
            elif "mesh-vpn" in self._config and interface in self._config["mesh-vpn"]:
                interfaceType = "tunnel"
            else:
                interfaceType = "other"

            if interfaceType not in ret:
                ret[interfaceType] = []

            ret[interfaceType].append(mac)

        if "l2tp" in ret:
            if "tunnel" in ret:
                ret["tunnel"] += ret["l2tp"]
            else:
                ret["tunnel"] = ret["l2tp"]

        return ret

    @staticmethod
    def getCPUInfo():
        ret = {}

        with open("/proc/cpuinfo", "r") as fh:
            for line in fh:
                lineMatch = re.match(r"^(.+?)[\t ]+:[\t ]+(.*)$", line, re.I)
                if lineMatch:
                    ret[lineMatch.group(1)] = lineMatch.group(2)

        if "model name" not in ret:
            ret["model name"] = ret["Processor"]

        return ret

    def getVPNFlag(self):
        mesh_idx = self._mesh_idx()
        if mesh_idx is None:
            return False
        reply = self._get_batadv().request_one(BATADV_CMD_GET_MESH, mesh_idx)
        if reply is None:
            return False
        attrs = dict(reply["attrs"])
        return attrs.get("BATADV_ATTR_GW_MODE", 0) == BATADV_GW_MODE_SERVER

    def _get(self):
        ret = {
            "hostname": socket.gethostname(),
            "network": {
                "addresses": self.getInterfaceAddresses(self._config["bridge"]),
                "mesh": {"bat0": {"interfaces": self.getBatmanInterfaces()}},
                "mac": lib.helper.getInterfaceMAC(self._config["batman"]),
            },
            "software": {
                "firmware": {
                    "base": lib.helper.call(["lsb_release", "-is"])[0],
                    "release": lib.helper.call(["lsb_release", "-ds"])[0],
                },
                "batman-adv": {
                    "version": open("/sys/module/batman_adv/version").read().strip(),
                    #                'compat': # /lib/gluon/mesh-batman-adv-core/compat
                },
                "status-page": {"api": 0},
                "autoupdater": {"enabled": False},
            },
            "hardware": {
                "model": self.getCPUInfo()["model name"],
                "nproc": int(lib.helper.call(["nproc"])[0]),
            },
            "owner": {},
            "system": {},
            "location": {},
            "vpn": self.getVPNFlag(),
        }

        #        if "mesh-vpn" in self._config and len(self._config["mesh-vpn"]) > 0:
        #            try:
        #                ret["software"]["fastd"] = {
        #                    "version": lib.helper.call(["fastd", "-v"])[0].split(" ")[1],
        #                    "enabled": True,
        #                }
        #            except:
        #                pass

        if "nodeinfo" in self._aliasOverlay:
            return lib.helper.merge(ret, self._aliasOverlay["nodeinfo"])
        else:
            return ret
