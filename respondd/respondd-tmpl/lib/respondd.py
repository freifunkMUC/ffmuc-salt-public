#!/usr/bin/env python3

import json
import time

import lib.helper


class Respondd:
    def __init__(self, config):
        self._config = config
        self._aliasOverlay = {}
        self.__cache = {}
        self.__cacheTime = 0
        try:
            with open("alias.json", "r") as fh:
                self._aliasOverlay = json.load(fh)
        except IOError:
            print("can't load alias.json!")

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
