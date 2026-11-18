#!/usr/bin/env python3
"""Kea DHCPv4 pool statistics in the dhcpd-pools output format.

Queries kea-dhcp4 over its control socket and prints the same JSON as
``dhcpd-pools --format=j`` (subnets, shared-networks, summary), so the
telegraf measurements and dashboards built for isc-dhcp-server keep working.
With --warning/--critical it behaves like a Nagios/Icinga check instead.

Field mapping (Kea statistic -> dhcpd-pools field):
  total-addresses                        -> defined
  assigned-addresses - declined-addresses -> used
  declined-addresses                     -> touched
"""

import argparse
import json
import socket
import sys

DEFAULT_SOCKET = "/run/kea/kea4-ctrl-socket"

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATUS_TEXT = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}


def kea_command(socket_path, command, timeout=5.0):
    """Send one command to the Kea control socket and return its arguments."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall(json.dumps({"command": command}).encode())
        # read until the response parses; Kea may keep the connection open
        data = b""
        response = None
        while response is None:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            try:
                response = json.loads(data)
            except ValueError:
                continue
    if response is None:
        raise RuntimeError(f"no complete response from Kea for '{command}'")
    if isinstance(response, list):
        response = response[0]
    if response.get("result") != 0:
        raise RuntimeError(f"Kea '{command}' failed: {response.get('text')}")
    return response.get("arguments", {})


def _stat(stats, name):
    """Return the current value of a Kea statistic, 0 if it is missing."""
    samples = stats.get(name)
    if not samples:
        return 0
    return int(samples[0][0])


def _counters(defined, used, touched):
    free = max(defined - used, 0)
    percent = round(100.0 * used / defined, 3) if defined else 0.0
    touch_count = used + touched
    touch_percent = round(100.0 * touch_count / defined, 3) if defined else 0.0
    return {
        "defined": defined,
        "used": used,
        "touched": touched,
        "free": free,
        "percent": percent,
        "touch_count": touch_count,
        "touch_percent": touch_percent,
    }


def _status(percent, warning, critical):
    if critical is not None and percent >= critical:
        return CRITICAL
    if warning is not None and percent >= warning:
        return WARNING
    return OK


def build_report(dhcp4_config, stats, warning=None, critical=None):
    """Build the dhcpd-pools style report from Kea's config and statistics."""
    networks = [
        (network.get("name", ""), network.get("subnet4", []))
        for network in dhcp4_config.get("shared-networks", [])
    ]
    if dhcp4_config.get("subnet4"):
        networks.append(("", dhcp4_config["subnet4"]))

    subnets, shared_networks = [], []
    totals = {"defined": 0, "used": 0, "touched": 0}
    for name, subnet_list in networks:
        net_totals = {"defined": 0, "used": 0, "touched": 0}
        for subnet in subnet_list:
            prefix = f"subnet[{subnet['id']}]"
            defined = _stat(stats, f"{prefix}.total-addresses")
            declined = _stat(stats, f"{prefix}.declined-addresses")
            used = max(_stat(stats, f"{prefix}.assigned-addresses") - declined, 0)
            for key, value in (
                ("defined", defined),
                ("used", used),
                ("touched", declined),
            ):
                net_totals[key] += value
            for pool in subnet.get("pools", []):
                first_ip, _, last_ip = pool["pool"].partition("-")
                entry = {
                    "location": name or subnet["subnet"],
                    "range": f"{first_ip.strip()} - {last_ip.strip()}",
                    "first_ip": first_ip.strip(),
                    "last_ip": last_ip.strip(),
                }
                entry.update(_counters(defined, used, declined))
                entry["status"] = _status(entry["percent"], warning, critical)
                subnets.append(entry)
                # Kea keeps statistics per subnet; count them for one pool only
                defined = used = declined = 0
        if name:
            entry = {"location": name}
            entry.update(_counters(**net_totals))
            entry["status"] = _status(entry["percent"], warning, critical)
            shared_networks.append(entry)
        for key in totals:
            totals[key] += net_totals[key]

    summary = {"location": "All networks"}
    summary.update(_counters(**totals))
    summary["status"] = _status(summary["percent"], warning, critical)
    return {"subnets": subnets, "shared-networks": shared_networks, "summary": summary}


def nagios_result(report):
    """Return (exit code, output line) for the Icinga check."""
    ranges = report["subnets"]
    worst = max((entry["status"] for entry in ranges), default=OK)
    counts = {
        code: sum(1 for entry in ranges if entry["status"] == code)
        for code in STATUS_TEXT
    }
    perfdata = " ".join(
        f"'{entry['location']}'={entry['used']};;;0;{entry['defined']}"
        for entry in ranges
    )
    text = (
        f"{STATUS_TEXT[worst]}: Ranges - crit: {counts[CRITICAL]} "
        f"warn: {counts[WARNING]} ok: {counts[OK]}"
    )
    return worst, f"{text} | {perfdata}" if perfdata else text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help="Kea control socket")
    parser.add_argument("--warning", type=float, help="warning threshold in percent")
    parser.add_argument("--critical", type=float, help="critical threshold in percent")
    args = parser.parse_args(argv)
    nagios = args.warning is not None or args.critical is not None

    try:
        dhcp4_config = kea_command(args.socket, "config-get").get("Dhcp4", {})
        stats = kea_command(args.socket, "statistic-get-all")
    except (OSError, RuntimeError, ValueError) as exc:
        print(
            f"UNKNOWN: cannot query Kea: {exc}",
            file=sys.stdout if nagios else sys.stderr,
        )
        return UNKNOWN if nagios else 1

    report = build_report(dhcp4_config, stats, args.warning, args.critical)
    if nagios:
        code, line = nagios_result(report)
        print(line)
        return code
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
