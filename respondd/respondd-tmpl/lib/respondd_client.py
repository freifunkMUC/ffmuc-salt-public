#!/usr/bin/env python3

import json
import logging
import socket
import struct
import zlib

from lib.batadv_netlink import BatadvNetlinkClient, list_hard_interfaces
from lib.ratelimit import rateLimit
from lib.nodeinfo import Nodeinfo
from lib.neighbours import Neighbours
from lib.statistics import Statistics

log = logging.getLogger(__name__)


class ResponddClient:
    def __init__(self, config):
        self._config = config

        if "rate_limit" in self._config:
            if "rate_limit_burst" not in self._config:
                self._config["rate_limit_burst"] = 10
            self.__RateLimit = rateLimit(
                self._config["rate_limit"], self._config["rate_limit_burst"]
            )
        else:
            self.__RateLimit = None

        self._batadv_nl = BatadvNetlinkClient()
        self._nodeinfo = Nodeinfo(self._config, self._batadv_nl)
        self._neighbours = Neighbours(self._config, self._batadv_nl)
        self._statistics = Statistics(self._config, self._batadv_nl)

        self._sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)

    @staticmethod
    def joinMCAST(sock, addr, ifname):
        group = socket.inet_pton(socket.AF_INET6, addr)
        if_idx = socket.if_nametoindex(ifname)
        sock.setsockopt(
            socket.IPPROTO_IPV6,
            socket.IPV6_JOIN_GROUP,
            group + struct.pack("I", if_idx),
        )

    def start(self):
        self._sock.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_BINDTODEVICE,
            bytes(self._config["bridge"].encode()),
        )
        self._sock.bind(("::", self._config["port"]))

        try:
            mesh_idx = socket.if_nametoindex(self._config["batman"])
        except OSError as e:
            log.warning("batman iface %s missing: %s", self._config["batman"], e)
            mesh_idx = None

        if mesh_idx is not None:
            for ifname in list_hard_interfaces(self._batadv_nl, mesh_idx):
                try:
                    self.joinMCAST(self._sock, self._config["addr"], ifname)
                except OSError as e:
                    log.warning("mcast join on %s failed: %s", ifname, e)

        self.joinMCAST(self._sock, self._config["addr"], self._config["bridge"])

        while True:
            try:
                msg, sourceAddress = self._sock.recvfrom(2048)
            except OSError:
                log.exception("recvfrom failed")
                continue

            try:
                decoded = str(msg, "UTF-8")
            except UnicodeDecodeError:
                log.warning("non-UTF-8 probe from %s", sourceAddress[0])
                continue

            try:
                msgSplit = decoded.split(" ")
                log.info("request from %s: %s", sourceAddress[0], decoded.rstrip())

                if msgSplit[0] == "GET":  # multi_request
                    responseStruct = {}
                    for request in msgSplit[1:]:
                        responseStruct[request] = self.buildStruct(request)
                    withCompression = True
                else:  # single_request
                    responseStruct = self.buildStruct(msgSplit[0])
                    withCompression = False

                self.sendStruct(sourceAddress, responseStruct, withCompression)
            except Exception:
                log.exception("error handling probe from %s", sourceAddress[0])

    def buildStruct(self, responseType):
        if self.__RateLimit is not None and not self.__RateLimit.limit():
            log.info("rate limit reached")
            return

        responseClass = None
        if responseType == "statistics":
            responseClass = self._statistics
        elif responseType == "nodeinfo":
            responseClass = self._nodeinfo
        elif responseType == "neighbours":
            responseClass = self._neighbours
        else:
            log.warning("unknown command: %s", responseType)
            return

        return responseClass.getStruct()

    def sendStruct(self, destAddress, responseStruct, withCompression):
        responseData = bytes(json.dumps(responseStruct, separators=(",", ":")), "UTF-8")
        log.debug("response to %s: %s", destAddress[0], responseData.decode("utf-8"))

        if withCompression:
            encoder = zlib.compressobj(
                zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15
            )  # The data may be decompressed using zlib and many zlib bindings using -15 as the window size parameter.
            responseData = encoder.compress(responseData) + encoder.flush()

        if self._config.get("dry_run"):
            return

        # Scope-id rewrite is a ffmuc-specific quirk: probes arriving via the
        # external VRF come back with scope id 'vrf_external', which isn't a
        # valid outbound scope for unicast replies. Substitute the local
        # client-bridge scope so sendto() can route the response.
        destAddressTmp = list(destAddress)
        destAddressTmp[0] = destAddressTmp[0].replace("vrf_external", "br-{{ site }}")
        self._sock.sendto(responseData, (destAddressTmp[0], 45124))
