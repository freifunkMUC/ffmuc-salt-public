#!/usr/bin/env python3

import json
import logging
import socket
import time

from lib.batadv_netlink import BatadvNetlinkClient
import lib.helper

log = logging.getLogger(__name__)


class Respondd:
    def __init__(self, config, batadv_nl=None):
        self._config = config
        self._batadv = batadv_nl
        self._aliasOverlay = {}
        self.__cache = {}
        self.__cacheTime = 0
        try:
            with open("alias.json", "r") as fh:
                self._aliasOverlay = json.load(fh)
        except IOError:
            log.warning("no alias.json found")

    def _get_batadv(self):
        # Shared client is injected by ResponddClient; fall back to a
        # private one for standalone test mode (ext-respondd.py -d).
        if self._batadv is None:
            self._batadv = BatadvNetlinkClient()
        return self._batadv

    def _mesh_idx(self):
        ifname = self._config["batman"]
        try:
            return socket.if_nametoindex(ifname)
        except OSError as e:
            log.warning("batman iface %s missing: %s", ifname, e)
            return None

    def getNodeID(self):
        if (
            "nodeinfo" in self._aliasOverlay
            and "node_id" in self._aliasOverlay["nodeinfo"]
        ):
            return self._aliasOverlay["nodeinfo"]["node_id"]
        return lib.helper.getInterfaceMAC(self._config["batman"]).replace(":", "")

    def getStruct(self):
        # Returned dict is shared with self.__cache — callers must not mutate.
        if (
            "caching" in self._config
            and time.time() - self.__cacheTime <= self._config["caching"]
        ):
            return self.__cache

        ret = self._get()
        ret["node_id"] = self.getNodeID()
        self.__cache = ret
        self.__cacheTime = time.time()
        return ret

    @staticmethod
    def _get():
        return {}
