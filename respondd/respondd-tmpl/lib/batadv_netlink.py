#!/usr/bin/env python3

# nla_map in batadv_msg below mirrors the BATADV_ATTR enum in
# /usr/include/linux/batman_adv.h. Positions are significant — shifting
# any row misaligns every subsequent attribute. Add new attributes at the
# end, in lockstep with the kernel header.

import logging

from pyroute2.netlink import NLM_F_DUMP, NLM_F_REQUEST, genlmsg
from pyroute2.netlink.exceptions import NetlinkError
from pyroute2.netlink.generic import GenericNetlinkSocket

log = logging.getLogger(__name__)

BATADV_CMD_GET_MESH = 1
BATADV_CMD_GET_HARDIF = 5
BATADV_CMD_GET_TRANSTABLE_LOCAL = 6
BATADV_CMD_GET_NEIGHBORS = 9
BATADV_CMD_GET_GATEWAYS = 10

# BATADV_ATTR_GW_MODE values (enum batadv_gw_modes in batman_adv.h)
BATADV_GW_MODE_OFF = 0
BATADV_GW_MODE_CLIENT = 1
BATADV_GW_MODE_SERVER = 2

# BATADV_ATTR_TT_FLAGS bits (enum batadv_tt_client_flags in batman_adv.h)
BATADV_TT_CLIENT_DEL = 1 << 0
BATADV_TT_CLIENT_ROAM = 1 << 1
BATADV_TT_CLIENT_WIFI = 1 << 4
BATADV_TT_CLIENT_ISOLA = 1 << 5
BATADV_TT_CLIENT_NOPURGE = 1 << 8
BATADV_TT_CLIENT_NEW = 1 << 9
BATADV_TT_CLIENT_PENDING = 1 << 10
BATADV_TT_CLIENT_TEMP = 1 << 11


class batadv_msg(genlmsg):
    # "none" for unread attrs — preserves enum positions without picking a type.
    nla_map = (
        ("BATADV_ATTR_UNSPEC", "none"),
        ("BATADV_ATTR_VERSION", "asciiz"),
        ("BATADV_ATTR_ALGO_NAME", "asciiz"),
        ("BATADV_ATTR_MESH_IFINDEX", "uint32"),
        ("BATADV_ATTR_MESH_IFNAME", "asciiz"),
        ("BATADV_ATTR_MESH_ADDRESS", "l2addr"),
        ("BATADV_ATTR_HARD_IFINDEX", "uint32"),
        ("BATADV_ATTR_HARD_IFNAME", "asciiz"),
        ("BATADV_ATTR_HARD_ADDRESS", "l2addr"),
        ("BATADV_ATTR_ORIG_ADDRESS", "l2addr"),
        ("BATADV_ATTR_TPMETER_RESULT", "none"),
        ("BATADV_ATTR_TPMETER_TEST_TIME", "none"),
        ("BATADV_ATTR_TPMETER_BYTES", "none"),
        ("BATADV_ATTR_TPMETER_COOKIE", "none"),
        ("BATADV_ATTR_PAD", "none"),
        ("BATADV_ATTR_ACTIVE", "none"),
        ("BATADV_ATTR_TT_ADDRESS", "l2addr"),
        ("BATADV_ATTR_TT_TTVN", "none"),
        ("BATADV_ATTR_TT_LAST_TTVN", "none"),
        ("BATADV_ATTR_TT_CRC32", "none"),
        ("BATADV_ATTR_TT_VID", "none"),
        ("BATADV_ATTR_TT_FLAGS", "uint32"),
        ("BATADV_ATTR_FLAG_BEST", "flag"),
        ("BATADV_ATTR_LAST_SEEN_MSECS", "uint32"),
        ("BATADV_ATTR_NEIGH_ADDRESS", "l2addr"),
        ("BATADV_ATTR_TQ", "uint8"),
        ("BATADV_ATTR_THROUGHPUT", "uint32"),
        ("BATADV_ATTR_BANDWIDTH_UP", "none"),
        ("BATADV_ATTR_BANDWIDTH_DOWN", "none"),
        ("BATADV_ATTR_ROUTER", "l2addr"),
        ("BATADV_ATTR_BLA_OWN", "none"),
        ("BATADV_ATTR_BLA_ADDRESS", "none"),
        ("BATADV_ATTR_BLA_VID", "none"),
        ("BATADV_ATTR_BLA_BACKBONE", "none"),
        ("BATADV_ATTR_BLA_CRC", "none"),
        ("BATADV_ATTR_DAT_CACHE_IP4ADDRESS", "none"),
        ("BATADV_ATTR_DAT_CACHE_HWADDRESS", "none"),
        ("BATADV_ATTR_DAT_CACHE_VID", "none"),
        ("BATADV_ATTR_MCAST_FLAGS", "none"),
        ("BATADV_ATTR_MCAST_FLAGS_PRIV", "none"),
        ("BATADV_ATTR_VLANID", "none"),
        ("BATADV_ATTR_AGGREGATED_OGMS_ENABLED", "none"),
        ("BATADV_ATTR_AP_ISOLATION_ENABLED", "none"),
        ("BATADV_ATTR_ISOLATION_MARK", "none"),
        ("BATADV_ATTR_ISOLATION_MASK", "none"),
        ("BATADV_ATTR_BONDING_ENABLED", "none"),
        ("BATADV_ATTR_BRIDGE_LOOP_AVOIDANCE_ENABLED", "none"),
        ("BATADV_ATTR_DISTRIBUTED_ARP_TABLE_ENABLED", "none"),
        ("BATADV_ATTR_FRAGMENTATION_ENABLED", "none"),
        ("BATADV_ATTR_GW_BANDWIDTH_DOWN", "none"),
        ("BATADV_ATTR_GW_BANDWIDTH_UP", "none"),
        ("BATADV_ATTR_GW_MODE", "uint8"),
        ("BATADV_ATTR_GW_SEL_CLASS", "none"),
        ("BATADV_ATTR_HOP_PENALTY", "none"),
        ("BATADV_ATTR_LOG_LEVEL", "none"),
        ("BATADV_ATTR_MULTICAST_FORCEFLOOD_ENABLED", "none"),
        ("BATADV_ATTR_NETWORK_CODING_ENABLED", "none"),
        ("BATADV_ATTR_ORIG_INTERVAL", "none"),
        ("BATADV_ATTR_ELP_INTERVAL", "none"),
        ("BATADV_ATTR_THROUGHPUT_OVERRIDE", "none"),
        ("BATADV_ATTR_MULTICAST_FANOUT", "none"),
    )


class BatadvNetlink(GenericNetlinkSocket):
    def __init__(self):
        super().__init__()
        # bind() can fail (e.g. batman_adv kmod not loaded); close the fd
        # opened by super().__init__() before re-raising so the facade's
        # reconnect loop doesn't leak descriptors.
        try:
            self.bind("batadv", batadv_msg)
        except Exception:
            self.close()
            raise

    def dump(self, cmd, mesh_ifindex):
        msg = batadv_msg()
        msg["cmd"] = cmd
        msg["version"] = 1
        msg["attrs"] = [("BATADV_ATTR_MESH_IFINDEX", mesh_ifindex)]
        return self.nlm_request(msg, self.prid, NLM_F_REQUEST | NLM_F_DUMP)

    def request_one(self, cmd, mesh_ifindex):
        # Not named get(): GenericNetlinkSocket.get() is called internally by
        # bind()/discovery() with a different signature, and shadowing it
        # breaks the bind handshake.
        msg = batadv_msg()
        msg["cmd"] = cmd
        msg["version"] = 1
        msg["attrs"] = [("BATADV_ATTR_MESH_IFINDEX", mesh_ifindex)]
        replies = self.nlm_request(msg, self.prid, NLM_F_REQUEST)
        return replies[0] if replies else None


class BatadvNetlinkClient:
    # Lazy bind + drop-on-error rebind. pyroute2 doesn't recover from a
    # stale seqno/prid after a failed request, so the only reliable
    # recovery is to discard the socket and let the next call re-bind.

    def __init__(self):
        self._nl = None

    def _ensure(self):
        if self._nl is None:
            self._nl = BatadvNetlink()

    def _reset(self):
        try:
            if self._nl is not None:
                self._nl.close()
        finally:
            self._nl = None

    def dump(self, cmd, mesh_ifindex):
        try:
            self._ensure()
            return self._nl.dump(cmd, mesh_ifindex)
        except (NetlinkError, OSError) as e:
            log.warning("batadv netlink dump cmd=%d failed: %s", cmd, e)
            self._reset()
            return []

    def request_one(self, cmd, mesh_ifindex):
        try:
            self._ensure()
            return self._nl.request_one(cmd, mesh_ifindex)
        except (NetlinkError, OSError) as e:
            log.warning("batadv netlink request_one cmd=%d failed: %s", cmd, e)
            self._reset()
            return None


def missing_attrs(attrs, mandatory):
    return any(name not in attrs for name in mandatory)


def list_hard_interfaces(client, mesh_ifindex):
    ret = {}
    for reply in client.dump(BATADV_CMD_GET_HARDIF, mesh_ifindex):
        attrs = dict(reply["attrs"])
        name = attrs.get("BATADV_ATTR_HARD_IFNAME")
        mac = attrs.get("BATADV_ATTR_HARD_ADDRESS")
        if name and mac:
            ret[name] = mac.lower()
    return ret
