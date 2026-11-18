#!/usr/bin/env python3
"""Minimal respondd responder for a Parker gateway (no batman-adv).

Answers respondd requests ("GET nodeinfo statistics neighbours" or a single
topic) by unicast on UDP port 1001. It binds only the addresses in the config
(localhost and the Nebula address), so only the local yanic and the yanic of
the other pgws can query it.

Usage: parker-respondd.py [CONFIG]           (default /etc/parker-respondd.json)
       parker-respondd.py --dump [CONFIG]    print the answer and exit
"""

import hashlib
import json
import os
import selectors
import socket
import subprocess
import sys
import time
import zlib

DEFAULT_CONFIG = "/etc/parker-respondd.json"
PORT = 1001
# A node with a handshake younger than this is connected (same as the wgkex route_gate).
HANDSHAKE_MAX_AGE = 180


def node_id(hostname):
    """A stable, locally administered MAC from the hostname (pgws have no bat0)."""
    raw = bytearray(hashlib.sha256(hostname.encode()).digest()[:6])
    raw[0] = (raw[0] | 0x02) & 0xFE
    return raw.hex()


def mac(nid):
    return ":".join(nid[i : i + 2] for i in range(0, 12, 2))


def run(cmd):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=5, check=True
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def ip_addresses(ifname, scope):
    out = run(["ip", "-j", "-6", "addr", "show", "dev", ifname, "scope", scope])
    try:
        data = json.loads(out or "[]")
    except ValueError:
        return []
    return [a["local"] for i in data for a in i.get("addr_info", []) if "local" in a]


def wireguard_peers(ifname, now=None):
    now = time.time() if now is None else now
    total = active = 0
    for line in run(["wg", "show", ifname, "latest-handshakes"]).splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        total += 1
        if parts[1].isdigit() and 0 < now - int(parts[1]) < HANDSHAKE_MAX_AGE:
            active += 1
    return {"peers": total, "active_peers": active}


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def meminfo():
    names = {
        "MemTotal": "total",
        "MemFree": "free",
        "MemAvailable": "available",
        "Buffers": "buffers",
        "Cached": "cached",
    }
    ret = {}
    for line in read("/proc/meminfo").splitlines():
        key, _, value = line.partition(":")
        if key in names:
            ret[names[key]] = int(value.split()[0])
    return ret


def os_release():
    ret = {}
    for line in read("/etc/os-release").splitlines():
        key, _, value = line.partition("=")
        ret[key] = value.strip('"')
    return ret


def cpu_model():
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return ""


def iface_counter(ifname, name):
    value = read(f"/sys/class/net/{ifname}/statistics/{name}").strip()
    return int(value) if value.isdigit() else 0


def merge(base, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


class Respondd:
    def __init__(self, config):
        self.config = config
        self.node_id = node_id(config["hostname"])
        self.wg = config.get("wireguard_interface", "wg-nodes")

    def nodeinfo(self):
        release = os_release()
        info = {
            "node_id": self.node_id,
            "hostname": self.config["hostname"],
            "network": {
                "mac": mac(self.node_id),
                "addresses": [
                    a
                    for i in self.config.get("address_interfaces", [])
                    for a in ip_addresses(i, "global")
                ],
                # Nodes report this link-local as gateway6: yanic then shows the pgw name.
                "mesh": {
                    self.wg: {"interfaces": {"tunnel": ip_addresses(self.wg, "link")}}
                },
            },
            "software": {
                "firmware": {
                    "base": release.get("NAME", "Linux"),
                    "release": release.get("PRETTY_NAME", ""),
                },
            },
            "hardware": {"model": cpu_model(), "nproc": os.cpu_count() or 1},
            "vpn": True,
        }
        return merge(info, self.config.get("nodeinfo", {}))

    def statistics(self):
        uptime, idletime = (read("/proc/uptime", "0 0").split() + ["0", "0"])[:2]
        load = (read("/proc/loadavg").split() + ["0", "0", "0", "0/0"])[:4]
        running, _, total = load[3].partition("/")
        disk = os.statvfs("/")
        return {
            "node_id": self.node_id,
            # The connected nodes are not clients: they would count twice in the global stats.
            "clients": {"total": 0},
            "uptime": float(uptime),
            "idletime": float(idletime),
            "loadavg": float(load[0]),
            "processes": {"running": int(running or 0), "total": int(total or 0)},
            "memory": meminfo(),
            "rootfs_usage": round(1 - disk.f_bfree / max(disk.f_blocks, 1), 4),
            "traffic": {
                "rx": {
                    "bytes": iface_counter(self.wg, "rx_bytes"),
                    "packets": iface_counter(self.wg, "rx_packets"),
                },
                "tx": {
                    "bytes": iface_counter(self.wg, "tx_bytes"),
                    "packets": iface_counter(self.wg, "tx_packets"),
                    "dropped": iface_counter(self.wg, "tx_dropped"),
                },
            },
            "wireguard": wireguard_peers(self.wg),
        }

    def neighbours(self):
        return {"node_id": self.node_id}

    def topic(self, name):
        if name in ("nodeinfo", "statistics", "neighbours"):
            return getattr(self, name)()
        return None

    def reply(self, msg):
        """Return the answer to one request, or None for an unknown request."""
        words = msg.decode("utf-8", "replace").split()
        if not words:
            return None
        if words[0] == "GET":
            data = {t: self.topic(t) for t in words[1:]}
            data = {k: v for k, v in data.items() if v is not None}
            if not data:
                return None
            enc = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15)
            raw = json.dumps(data, separators=(",", ":")).encode()
            return enc.compress(raw) + enc.flush()
        data = self.topic(words[0])
        if data is None:
            return None
        return json.dumps(data, separators=(",", ":")).encode()


def open_sockets(addresses, port=PORT):
    socks = []
    for addr in addresses:
        family = socket.AF_INET6 if ":" in addr else socket.AF_INET
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.bind((addr, port))
        socks.append(sock)
    return socks


def serve(responder, socks, once=False):
    sel = selectors.DefaultSelector()
    for sock in socks:
        sel.register(sock, selectors.EVENT_READ)
    while True:
        for key, _ in sel.select():
            msg, source = key.fileobj.recvfrom(1500)
            try:
                answer = responder.reply(msg)
            except (
                Exception
            ) as e:  # noqa: BLE001 - one bad request must not stop the daemon
                print(f"request from {source[0]} failed: {e}", file=sys.stderr)
                continue
            if answer is not None:
                key.fileobj.sendto(answer, source)
        if once:
            return


def main(argv):
    dump = "--dump" in argv
    args = [a for a in argv if a != "--dump"]
    with open(args[0] if args else DEFAULT_CONFIG) as f:
        config = json.load(f)
    responder = Respondd(config)
    if dump:
        for t in ("nodeinfo", "statistics", "neighbours"):
            print(json.dumps({t: responder.topic(t)}, indent=2))
        return
    serve(responder, open_sockets(config["listen"], config.get("port", PORT)))


if __name__ == "__main__":
    main(sys.argv[1:])
