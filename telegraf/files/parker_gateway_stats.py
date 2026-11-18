#!/usr/bin/env python3
"""BIRD and WireGuard stats of a Parker gateway for telegraf (inputs.exec, influx line protocol).

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

The BFD neighbors are the other gateways of the site (router addresses, not nodes).
"""

import re
import subprocess
import sys
import time

BIRDC = "/usr/sbin/birdc"
WG = "/usr/bin/wg"
WG_INTERFACE = "wg-nodes"

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


def main():
    lines = bird_lines(
        run([BIRDC, "-r", "show", "protocols", "all"]),
        run([BIRDC, "-r", "show", "bfd", "sessions"]),
    )
    lines += wireguard_lines(
        run([WG, "show", WG_INTERFACE, "latest-handshakes"]), int(time.time())
    )
    sys.stdout.write("".join(line + "\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
