#!/usr/bin/env python3
"""Select a batch of classic nodes for the Parker canary.

Reads map data and the Parker manifest. Prints the eligible nodes, the skip
reasons and a proposed batch. With --write it appends the batch to
nginx/parker-canary.yaml. It does not change anything else.

Run: python3 nginx/parker-canary-select.py --size 25 [--write]
         [--link-history links.json]

links.json is the yanic InfluxDB answer to:
  SELECT count(tq) FROM link WHERE time > now() - 14d
  GROUP BY "source.id","target.id","type"
Nodes with a mesh link in it are skipped, also when the neighbour is offline now.
"""

import argparse
import collections
import ipaddress
import json
import os
import re
import urllib.request

import yaml

MAP_URL = "https://map.ffmuc.net/data/meshviewer.json"
MANIFEST_URL = "https://firmware.ffmuc.net/parker/sysupgrade/parker.manifest"
CANARY_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "parker-canary.yaml"
)
BRANCHES = ["experimental", "testing", "stable"]
GUARDED = ["experimental", "testing"]
MIN_CLASSIC = 3
# Canary nodes must be real routers: no VMs, no gateway or uplink nodes
VM_TARGETS = {"x86", "armsr"}
GATEWAY_LIKE = re.compile(r"(^|[^a-z])(gw|gateway|core|uplink)([^a-z]|$)", re.I)

# OpenWrt 24.10 changed DEVICE_COMPAT_VERSION for these images. Parker
# (Gluon v2025.1) cannot sysupgrade them from an older Gluon base.
COMPAT_CHANGED = {
    "linksys-e4200-v2-viper",
    "linksys-e8450-ubi",
    "linksys-ea4500-viper",
    "netgear-nighthawk-x4s-r7800",
    "ocedo-panda",
    "tp-link-archer-c2600",
    "ubiquiti-edgerouter-x",
    "ubiquiti-edgerouter-x-sfp",
    "xiaomi-redmi-router-ax6s",
}
NEW_BASE = re.compile(r"^gluon-v(\d{4})\.(\d+)")

# Releases that nginx sends to gluon-v2025.1.x_v2023.1.x (upgrade path to Parker)
UPGRADE_PATH = re.compile(
    r"^v(2023\.(8|11)\.\d+|2024\.\d+\.\d+|2023\.12\.2-next|2024\.\d+\.\d+-next"
    r"|2025\.\d+\.\d+|2025\.\d+\.\d+-main|2026\.\d+\.\d+)$"
)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "parker-canary-select"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode()


def parker_images(manifest):
    images = set()
    for line in manifest.split("\n---")[0].splitlines():
        fields = line.split()
        if len(fields) >= 5 and "=" not in fields[0]:
            images.add(fields[0])
    return images


def public_ipv6(node):
    out = []
    for address in node.get("addresses") or []:
        ip = ipaddress.ip_address(address)
        if ip.version == 6 and ip.is_global:
            out.append(str(ip))
    return out


def clients(node):
    return node.get("clients") or 0


def old_base(firmware):
    m = NEW_BASE.match(firmware.get("base") or "")
    return not m or (int(m.group(1)), int(m.group(2))) < (2025, 1)


def mesh_links(links, gateways):
    meshed = set()
    for source, target, kind in links:
        if kind == "vpn" or source in gateways or target in gateways:
            continue
        meshed.update((source, target))
    return meshed


def history_links(answer):
    out = []
    for series in answer["results"][0].get("series") or []:
        tags = series["tags"]
        out.append((tags["source.id"], tags["target.id"], tags.get("type")))
    return out


def is_classic(node):
    release = (node.get("firmware") or {}).get("release") or ""
    return release.startswith("v") and "parker" not in release


def select(data, images, listed, size, history=()):
    nodes = data["nodes"]
    gateways = {n["node_id"] for n in nodes if n.get("is_gateway")}
    meshed = mesh_links(
        [(l["source"], l["target"], l.get("type")) for l in data["links"]], gateways
    )
    meshed_before = mesh_links(history, gateways) - meshed

    # Online classic nodes per (image, branch), without the listed ones
    remaining = collections.Counter()
    for n in nodes:
        if n.get("is_online") and is_classic(n) and n["node_id"] not in listed:
            branch = (n.get("autoupdater") or {}).get("branch")
            remaining[(n["firmware"].get("image_name"), branch)] += 1

    skipped = collections.Counter()
    eligible = []
    for n in nodes:
        firmware = n.get("firmware") or {}
        autoupdater = n.get("autoupdater") or {}
        if not n.get("is_online") or n.get("is_gateway") or not is_classic(n):
            continue
        if n["node_id"] in listed:
            reason = "already listed"
        elif autoupdater.get("branch") not in BRANCHES:
            reason = "branch %s" % autoupdater.get("branch")
        elif not autoupdater.get("enabled"):
            reason = "autoupdater off"
        elif not UPGRADE_PATH.match(firmware.get("release", "")):
            reason = "no upgrade path from %s" % firmware.get("release")
        elif firmware.get("target") in VM_TARGETS:
            reason = "VM image"
        elif GATEWAY_LIKE.search(n.get("hostname") or ""):
            reason = "gateway-like hostname"
        elif firmware.get("image_name") not in images:
            reason = "no Parker image"
        elif firmware.get("image_name") in COMPAT_CHANGED and old_base(firmware):
            reason = "compat_version changed"
        elif n["node_id"] in meshed:
            reason = "mesh neighbours"
        elif n["node_id"] in meshed_before:
            reason = "mesh neighbours in history"
        elif not public_ipv6(n):
            reason = "no public IPv6"
        else:
            eligible.append(n)
            continue
        skipped[reason.split(" from ")[0]] += 1

    # Round robin over branches, prefer models with few picks, then many clients
    pool = {b: [] for b in BRANCHES}
    for n in sorted(eligible, key=lambda n: (-clients(n), n["node_id"])):
        pool[n["autoupdater"]["branch"]].append(n)
    picked_models = collections.Counter()
    batch = []
    while len(batch) < size and any(pool.values()):
        for branch in BRANCHES:
            if len(batch) >= size:
                break
            while pool[branch]:
                pool[branch].sort(
                    key=lambda n: picked_models[n["firmware"]["image_name"]]
                )
                n = pool[branch].pop(0)
                key = (n["firmware"]["image_name"], branch)
                if branch in GUARDED and remaining[key] - 1 < MIN_CLASSIC:
                    skipped["guard: keep %d classic per model" % MIN_CLASSIC] += 1
                    continue
                remaining[key] -= 1
                picked_models[key[0]] += 1
                batch.append(n)
                break
    return eligible, skipped, batch


def to_yaml(batch):
    out = []
    for n in batch:
        out.append("  - node_id: %s\n" % json.dumps(n["node_id"]))
        out.append("    hostname: %s\n" % json.dumps(n.get("hostname", "")))
        out.append("    model: %s\n" % json.dumps(n.get("model", "")))
        out.append("    image_name: %s\n" % json.dumps(n["firmware"]["image_name"]))
        out.append("    branch: %s\n" % n["autoupdater"]["branch"])
        out.append("    clients: %d\n" % clients(n))
        out.append("    addresses:\n")
        for address in public_ipv6(n):
            out.append("      - %s\n" % json.dumps(address))
    return "".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--size", type=int, default=25)
    parser.add_argument("--write", action="store_true", help="append to " + CANARY_FILE)
    parser.add_argument("--map", default=MAP_URL)
    parser.add_argument("--manifest", default=MANIFEST_URL)
    parser.add_argument("--link-history", help="yanic InfluxDB link answer (JSON)")
    args = parser.parse_args()

    with open(CANARY_FILE) as f:
        text = f.read()
    listed = {n["node_id"] for n in (yaml.safe_load(text) or {}).get("nodes") or []}
    data = json.loads(fetch(args.map))
    images = parker_images(fetch(args.manifest))

    history = []
    if args.link_history:
        with open(args.link_history) as f:
            history = history_links(json.load(f))
    eligible, skipped, batch = select(data, images, listed, args.size, history)
    print("Eligible: %d" % len(eligible))
    print(
        "Eligible per branch: %s"
        % dict(collections.Counter(n["autoupdater"]["branch"] for n in eligible))
    )
    print("Skipped:")
    for reason, count in skipped.most_common():
        print("  %5d  %s" % (count, reason))
    print("Batch (%d):" % len(batch))
    for n in batch:
        print(
            "  %-12s %-13s %4d %-30s %s"
            % (
                n["node_id"],
                n["autoupdater"]["branch"],
                clients(n),
                n["firmware"]["image_name"],
                n.get("hostname"),
            )
        )

    if args.write and batch:
        text = text.replace("nodes: []", "nodes:")
        if not text.endswith("\n"):
            text += "\n"
        with open(CANARY_FILE, "w") as f:
            f.write(text + to_yaml(batch))
        print("Appended %d nodes to %s" % (len(batch), CANARY_FILE))


if __name__ == "__main__":
    main()
