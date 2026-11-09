#!/usr/bin/env python3
"""Validate every Komodo stack: `docker compose config -q --no-interpolate`.

Runs compose as Komodo does (cwd = run_directory, the stack's file_paths) so
relative includes resolve the same. --no-interpolate skips ${VAR} resolution,
because secrets and variables only exist on the host at deploy time; YAML,
schema and file errors still fail. Also fails for compose files below stacks/
that no stack in komodo-sync/stacks.toml lists.
"""
import fnmatch
import os
import subprocess
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

with open("stacks/komodo-sync/stacks.toml", "rb") as fh:
    stacks = tomllib.load(fh)["stack"]

failed = 0
broken = 0
listed = set()
for s in stacks:
    cfg = s["config"]
    run_dir = cfg["run_directory"]
    files = cfg.get("file_paths", ["compose.yaml"])
    listed.update(os.path.normpath(os.path.join(run_dir, f)) for f in files)
    cmd = ["docker", "compose"]
    for f in files:
        cmd += ["-f", f]
    cmd += ["config", "-q", "--no-interpolate"]
    r = subprocess.run(cmd, cwd=os.path.join(ROOT, run_dir), capture_output=True, text=True)
    if r.returncode:
        broken += 1
        failed += 1
        print(f"::error title=compose config failed::{s['name']} ({run_dir})")
        print(r.stderr.strip())
    else:
        print(f"ok   {s['name']}")

for dirpath, _, names in os.walk("stacks"):
    if dirpath.startswith(("stacks/komodo-sync", "stacks/build")):
        continue
    for n in names:
        p = os.path.normpath(os.path.join(dirpath, n))
        if any(fnmatch.fnmatch(n, g) for g in ("compose*.y*ml", "docker-compose*.y*ml")) and p not in listed:
            failed += 1
            print(f"::error file={p}::compose file not listed in komodo-sync/stacks.toml")

print(f"{len(stacks) - broken} of {len(stacks)} stacks ok, {failed} failed")
sys.exit(1 if failed else 0)
