#!/usr/bin/env python3
"""haproxy peers and stick table stats for telegraf (inputs.exec, influx line protocol).

The stats CSV read by inputs.haproxy has no peers information, so this asks the
runtime API for "show peers" and "show table" and emits

  haproxy_peer,section=<peers section>,peer=<remote peer>
      connected=0|1i,last_status="ESTA",last_hdshk_s=<float, omitted if never>,
      tx_hbt,rx_hbt,no_hbt,new_conn,proto_err,coll (cumulative counters)
  haproxy_stick_table,table=<name> used=<int>i,size=<int>i
"""

import re
import socket
import sys

SOCKET = "/run/haproxy/api.sock"
COUNTERS = ("tx_hbt", "rx_hbt", "no_hbt", "new_conn", "proto_err", "coll")

SECTION_RE = re.compile(r"^0x[0-9a-f]+: \[[^\]]*\] id=(\S+)")
PEER_RE = re.compile(r"^\s+0x[0-9a-f]+: id=([^(\s]+)\((local|remote),")
TABLE_RE = re.compile(r"^# table: ([^,]+), type: [^,]+, size:(\d+), used:(\d+)")
DURATION_RE = re.compile(r"(\d+)(ms|d|h|m|s)")
UNITS = {"d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 0.001}


def query(command, path=SOCKET):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(3)
        sock.connect(path)
        sock.sendall(command.encode() + b"\n")
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode(errors="replace")


def duration_s(value):
    """haproxy human_time ("13h54m", "2s", "<NEVER>") to seconds, None if not a duration."""
    parts = DURATION_RE.findall(value)
    if not parts or "".join(n + u for n, u in parts) != value:
        return None
    return float(sum(int(n) * UNITS[u] for n, u in parts))


def parse_peers(text):
    """Remote peers as dicts with section, peer and the key=value pairs of their header lines."""
    peers = []
    section = None
    current = None
    for line in text.splitlines():
        match = SECTION_RE.match(line)
        if match:
            section, current = match.group(1), None
            continue
        match = PEER_RE.match(line)
        if match:
            current = None
            if match.group(2) == "remote" and section:
                current = {"section": section, "peer": match.group(1)}
                peers.append(current)
            else:
                continue
        elif current is None:
            continue
        elif (
            "shared tables:" in line
            or "remote_table:" in line
            or "last_local_table:" in line
        ):
            # per table details follow, their id=/update= keys are not the peer's
            current = None
            continue
        for token in line.split():
            key, sep, value = token.partition("=")
            if sep and key != "id":
                current.setdefault(key, value)
    return peers


def parse_tables(text):
    return [
        {"table": m.group(1), "size": int(m.group(2)), "used": int(m.group(3))}
        for m in map(TABLE_RE.match, text.splitlines())
        if m
    ]


def tag(value):
    return re.sub(r"([,= ])", r"\\\1", value)


def peer_line(peer):
    fields = {
        "connected": "1i" if peer.get("state") == "EST" else "0i",
        "last_status": '"%s"'
        % peer.get("last_status", "").replace("\\", "\\\\").replace('"', '\\"'),
    }
    hdshk = duration_s(peer.get("last_hdshk", ""))
    if hdshk is not None:
        fields["last_hdshk_s"] = repr(hdshk)
    for counter in COUNTERS:
        if peer.get(counter, "").isdigit():
            fields[counter] = peer[counter] + "i"
    return "haproxy_peer,section=%s,peer=%s %s" % (
        tag(peer["section"]),
        tag(peer["peer"]),
        ",".join("%s=%s" % kv for kv in fields.items()),
    )


def table_line(table):
    return "haproxy_stick_table,table=%s used=%di,size=%di" % (
        tag(table["table"]),
        table["used"],
        table["size"],
    )


def main():
    lines = [peer_line(p) for p in parse_peers(query("show peers"))]
    lines += [table_line(t) for t in parse_tables(query("show table"))]
    if lines:
        print("\n".join(lines))


if __name__ == "__main__":
    try:
        main()
    except OSError as err:
        print("haproxy_peers_stats: %s" % err, file=sys.stderr)
        sys.exit(1)
