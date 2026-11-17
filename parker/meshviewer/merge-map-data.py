#!/usr/bin/env python3
"""Merge the meshviewer.json of all Parker sites into one file.

A node has a tunnel to each site, so the yanic of each site reports it.
meshviewer does not merge nodes with the same node_id, so this script does:
the copy with the newest lastseen wins.

Usage: merge-map-data.py LOCAL_FILE OUT_FILE [REMOTE_URL ...]
"""

import json
import os
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

# Use the last good copy of a remote site for this long if a fetch fails.
REMOTE_CACHE_MAX_AGE = 600


def lastseen(node):
    try:
        return datetime.strptime(node.get("lastseen", ""), "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def write_atomic(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def load_remote(url, cache):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.load(r)
        write_atomic(cache, data)
        return data
    except Exception as e:  # noqa: BLE001 - any failure falls back to the cache
        print(f"fetch {url} failed: {e}", file=sys.stderr)
    if (
        os.path.exists(cache)
        and time.time() - os.path.getmtime(cache) < REMOTE_CACHE_MAX_AGE
    ):
        with open(cache) as f:
            return json.load(f)
    return None


def merge(sources):
    nodes, links, timestamp = {}, {}, ""
    for data in sources:
        timestamp = max(timestamp, data.get("timestamp", ""))
        for node in data.get("nodes", []):
            old = nodes.get(node["node_id"])
            if old is None or lastseen(node) > lastseen(old):
                nodes[node["node_id"]] = node
        for link in data.get("links", []):
            links.setdefault((link["source"], link["target"], link.get("type")), link)
    return {
        "timestamp": timestamp,
        "nodes": list(nodes.values()),
        "links": list(links.values()),
    }


def main():
    local, out, urls = sys.argv[1], sys.argv[2], sys.argv[3:]
    sources = []
    with open(local) as f:
        sources.append(json.load(f))
    for i, url in enumerate(urls):
        data = load_remote(
            url, os.path.join(os.path.dirname(local), f"remote-{i}.json")
        )
        if data is not None:
            sources.append(data)
    write_atomic(out, merge(sources))


if __name__ == "__main__":
    main()
