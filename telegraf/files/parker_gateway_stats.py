#!/usr/bin/env python3
"""BIRD, WireGuard and Jool NAT64 stats of a Parker gateway for telegraf (inputs.exec, influx line protocol).

Read only: the commands below are the only ones that sudo allows for telegraf
(see /etc/sudoers.d/telegraf_parker_gateway). birdc runs in restricted mode (-r),
so it cannot change the BIRD configuration or a protocol state.

Output (aggregates only, no node keys, prefixes or addresses):

  bird_daemon up=0|1i
  bird_protocol,protocol=<name>,proto=<BGP|BFD|...> up=0|1i,established=0|1i,state="",info=""
  bird_channel,protocol=<name>,channel=<ipv4|ipv6> imported=,filtered=,exported=,preferred=
  bird_bfd_session,protocol=<name>,interface=<ifname>,neighbor=<router address>
      up=0|1i,state="Up",interval=<s>,timeout=<s>
  wireguard_peers,interface=<ifname> peers=,handshake_3m=,handshake_15m=,handshake_never=
  parker_xpgw_traffic,direction=<uplink_to_partner|partner_to_nodes> bytes=,packets=
      node traffic between the pgws of a site, from the nftables counters of
      parker/xpgw-counters (cumulative, reset when the table is loaded again)
  parker_nat64_source,source=<node_clat|client>,direction=<to_nat64|from_nat64> bytes=,packets=
      NAT64 (Jool) traffic of the nodes on this pgw, split by source: node CLAT (second /64
      of the node /63) or client side (first /64). Same nftables table as above.
  jool_daemon up=0|1i
  jool_stats received6=,received4=,success=,bib_entries=,sessions=,
      icmp4err_success=,icmp6err_success=        NAT64 (Jool) packet counters
  jool_drop,reason=<JSTAT name without JSTAT_> packets=
      one line per non-zero drop counter of `jool stats display`
  jool_protocol,protocol=<tcp|udp|icmp> sessions=,bib=,pool4_ports=
      sessions and BIB entries (one pool4 port each), and the pool4 size

Jool runs in the network namespace jool (parker/plat). The script only counts the
lines of the session and BIB tables. It never prints client addresses or ports.

The BFD neighbors are the other gateways of the site (router addresses, not nodes).
"""

import json
import re
import subprocess
import sys
import time

BIRDC = "/usr/sbin/birdc"
WG = "/usr/bin/wg"
WG_INTERFACE = "wg-nodes"
NFT = "/usr/sbin/nft"
XPGW_COUNTERS = ("uplink_to_partner", "partner_to_nodes")
NAT64_COUNTERS = {
    "nat64_node_clat_to_nat64": ("node_clat", "to_nat64"),
    "nat64_client_to_nat64": ("client", "to_nat64"),
    "nat64_node_clat_from_nat64": ("node_clat", "from_nat64"),
    "nat64_client_from_nat64": ("client", "from_nat64"),
}
JOOL = ["/usr/sbin/ip", "netns", "exec", "jool", "/usr/bin/jool", "-i", "default"]
JOOL_PROTOCOLS = ("tcp", "udp", "icmp")
JOOL_STATS = {
    "JSTAT_RECEIVED6": "received6",
    "JSTAT_RECEIVED4": "received4",
    "JSTAT_SUCCESS": "success",
    "JSTAT_BIB_ENTRIES": "bib_entries",
    "JSTAT_SESSIONS": "sessions",
    "JSTAT_ICMP6ERR_SUCCESS": "icmp6err_success",
    "JSTAT_ICMP4ERR_SUCCESS": "icmp4err_success",
}

TIME_TOKEN = re.compile(r"^[0-9][0-9:.T+-]*$")
ROUTES_RE = re.compile(r"(\d+) (imported|filtered|exported|preferred)")
CHANNEL_RE = re.compile(r"^\s+Channel (\S+)$")


def run(cmd):
    """Returns the stdout of a sudo command, or None if it fails."""
    try:
        proc = subprocess.run(
            ["/usr/bin/sudo", "-n", *cmd],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def escape_tag(value):
    return re.sub(r"([ ,=\\])", r"\\\1", value)


def escape_str(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_protocols(output):
    """Parses `birdc show protocols all` into protocols and their channels."""
    protocols = []
    current = None
    channel = None
    for line in output.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            fields = line.split()
            if len(fields) < 4 or fields[0] in ("BIRD", "Name", "Access"):
                current = None
                continue
            name, proto, state, rest = fields[0], fields[1], fields[3], fields[4:]
            while rest and TIME_TOKEN.match(rest[0]):
                rest = rest[1:]
            current = {
                "name": name,
                "proto": proto,
                "state": state,
                "info": " ".join(rest),
                "channels": {},
            }
            protocols.append(current)
            channel = None
            continue
        if current is None:
            continue
        match = CHANNEL_RE.match(line)
        if match:
            channel = match.group(1)
            continue
        if channel and line.strip().startswith("Routes:"):
            current["channels"][channel] = {
                kind: int(count) for count, kind in ROUTES_RE.findall(line)
            }
    return protocols


def parse_bfd_sessions(output):
    """Parses `birdc show bfd sessions`."""
    sessions = []
    protocol = None
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 1 and fields[0].endswith(":"):
            protocol = fields[0][:-1]
            continue
        if protocol is None or len(fields) < 6 or fields[0] == "IP":
            continue
        try:
            interval, timeout = float(fields[-2]), float(fields[-1])
        except ValueError:
            continue
        sessions.append(
            {
                "protocol": protocol,
                "neighbor": fields[0],
                "interface": fields[1],
                "state": fields[2],
                "interval": interval,
                "timeout": timeout,
            }
        )
    return sessions


def count_handshakes(output, now):
    """Counts peers by handshake age. Never returns the peer keys."""
    counts = {"peers": 0, "handshake_3m": 0, "handshake_15m": 0, "handshake_never": 0}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            stamp = int(fields[1])
        except ValueError:
            continue
        counts["peers"] += 1
        if stamp == 0:
            counts["handshake_never"] += 1
            continue
        age = now - stamp
        if age <= 180:
            counts["handshake_3m"] += 1
        if age <= 900:
            counts["handshake_15m"] += 1
    return counts


def bird_lines(protocols_out, bfd_out):
    if protocols_out is None:
        return ["bird_daemon up=0i"]
    lines = ["bird_daemon up=1i"]
    for proto in parse_protocols(protocols_out):
        tags = (
            f"protocol={escape_tag(proto['name'])},proto={escape_tag(proto['proto'])}"
        )
        up = int(proto["state"] == "up")
        established = int(proto["info"].startswith("Established"))
        lines.append(
            f"bird_protocol,{tags} up={up}i,established={established}i,"
            f"state={escape_str(proto['state'])},info={escape_str(proto['info'])}"
        )
        for channel, routes in sorted(proto["channels"].items()):
            if not routes:
                continue
            fields = ",".join(f"{kind}={count}i" for kind, count in routes.items())
            lines.append(
                f"bird_channel,protocol={escape_tag(proto['name'])},"
                f"channel={escape_tag(channel)} {fields}"
            )
    for session in parse_bfd_sessions(bfd_out or ""):
        lines.append(
            f"bird_bfd_session,protocol={escape_tag(session['protocol'])},"
            f"interface={escape_tag(session['interface'])},"
            f"neighbor={escape_tag(session['neighbor'])} "
            f"up={int(session['state'] == 'Up')}i,state={escape_str(session['state'])},"
            f"interval={session['interval']},timeout={session['timeout']}"
        )
    return lines


def wireguard_lines(handshakes_out, now):
    if handshakes_out is None:
        return []
    counts = count_handshakes(handshakes_out, now)
    fields = ",".join(f"{key}={value}i" for key, value in counts.items())
    return [f"wireguard_peers,interface={escape_tag(WG_INTERFACE)} {fields}"]


def nft_counters(nft_json):
    """Reads the named counters of table inet parker_stats (`nft -j list counters`).

    Returns {name: (bytes, packets)}.
    """
    if not nft_json:
        return {}
    try:
        objects = json.loads(nft_json).get("nftables", [])
    except (ValueError, AttributeError):
        return {}
    counters = {}
    for obj in objects:
        counter = obj.get("counter") if isinstance(obj, dict) else None
        if counter and "name" in counter:
            counters[counter["name"]] = (int(counter["bytes"]), int(counter["packets"]))
    return counters


def xpgw_lines(counters):
    lines = []
    for name in XPGW_COUNTERS:
        if name not in counters:
            continue
        byte_count, packets = counters[name]
        lines.append(
            f"parker_xpgw_traffic,direction={name} "
            f"bytes={byte_count}i,packets={packets}i"
        )
    return sorted(lines)


def nat64_source_lines(counters):
    lines = []
    for name, (source, direction) in NAT64_COUNTERS.items():
        if name not in counters:
            continue
        byte_count, packets = counters[name]
        lines.append(
            f"parker_nat64_source,source={source},direction={direction} "
            f"bytes={byte_count}i,packets={packets}i"
        )
    return sorted(lines)


def parse_jool_stats(output):
    """Parses `jool stats display --all --csv` into {name: value}."""
    stats = {}
    for line in output.splitlines():
        fields = line.strip().split(",")
        if len(fields) != 2 or not fields[0].startswith("JSTAT"):
            continue
        try:
            stats[fields[0]] = int(fields[1])
        except ValueError:
            continue
    return stats


def pool4_ports(output):
    """Sums the port ranges of `jool pool4 display --csv` (one protocol)."""
    total = 0
    for line in output.splitlines():
        fields = line.strip().split(",")
        if len(fields) < 5:
            continue
        try:
            total += int(fields[4]) - int(fields[3]) + 1
        except ValueError:
            continue
    return total


def count_rows(output):
    return sum(1 for line in output.splitlines() if line.strip())


def jool_lines(stats_out, tables):
    """tables: {protocol: (session_out, bib_out, pool4_out)}, each None if it fails."""
    if stats_out is None:
        return ["jool_daemon up=0i"]
    stats = parse_jool_stats(stats_out)
    lines = ["jool_daemon up=1i"]
    fields = ",".join(
        f"{field}={stats[name]}i" for name, field in JOOL_STATS.items() if name in stats
    )
    if fields:
        lines.append(f"jool_stats {fields}")
    for name, value in sorted(stats.items()):
        if value == 0 or name in JOOL_STATS or name.startswith("JSTAT_JOOLD_"):
            continue
        # JSTAT_PKT_TOO_BIG -> PKT_TOO_BIG, JSTAT64_TTL -> 64_TTL
        reason = name.removeprefix("JSTAT").removeprefix("_")
        lines.append(f"jool_drop,reason={escape_tag(reason)} packets={value}i")
    for proto in JOOL_PROTOCOLS:
        session_out, bib_out, pool4_out = tables.get(proto, (None, None, None))
        values = []
        if session_out is not None:
            values.append(f"sessions={count_rows(session_out)}i")
        if bib_out is not None:
            values.append(f"bib={count_rows(bib_out)}i")
        if pool4_out is not None:
            values.append(f"pool4_ports={pool4_ports(pool4_out)}i")
        if values:
            lines.append(f"jool_protocol,protocol={proto} {','.join(values)}")
    return lines


def jool_tables():
    tables = {}
    for proto in JOOL_PROTOCOLS:
        tables[proto] = (
            run(
                [
                    *JOOL,
                    "session",
                    "display",
                    f"--{proto}",
                    "--numeric",
                    "--csv",
                    "--no-headers",
                ]
            ),
            run(
                [
                    *JOOL,
                    "bib",
                    "display",
                    f"--{proto}",
                    "--numeric",
                    "--csv",
                    "--no-headers",
                ]
            ),
            run([*JOOL, "pool4", "display", f"--{proto}", "--csv", "--no-headers"]),
        )
    return tables


def main():
    lines = bird_lines(
        run([BIRDC, "-r", "show", "protocols", "all"]),
        run([BIRDC, "-r", "show", "bfd", "sessions"]),
    )
    lines += wireguard_lines(
        run([WG, "show", WG_INTERFACE, "latest-handshakes"]), int(time.time())
    )
    counters = nft_counters(
        run([NFT, "-j", "list", "counters", "table", "inet", "parker_stats"])
    )
    lines += xpgw_lines(counters)
    lines += nat64_source_lines(counters)
    stats_out = run([*JOOL, "stats", "display", "--all", "--csv"])
    lines += jool_lines(stats_out, jool_tables() if stats_out is not None else {})
    sys.stdout.write("".join(line + "\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
