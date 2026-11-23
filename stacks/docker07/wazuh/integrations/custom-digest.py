"""Wazuh integration: collect alerts for a window and post one grouped chat message.

ossec.conf: <integration><name>custom-digest</name><hook_url>URL</hook_url><level>10</level>
<alert_format>json</alert_format><options>{"window": 300}</options></integration>

integratord waits for this process, so it only spools the alert and returns. The first
call without a pending flush forks a detached flusher that sleeps for the window, takes
the spool and posts a Slack-compatible {"text": ...} (works for Slack and Mattermost).
Options (JSON): window (seconds, default 300), max_chars (default 3500), max_agents
(default 10), max_packages (default 8).
"""

import fcntl
import json
import os
import ssl
import sys
import time
import urllib.request

WAZUH_PATH = os.environ.get("WAZUH_PATH") or os.path.dirname(
    os.path.dirname(os.path.realpath(__file__))
)
LOG_FILE = os.path.join(WAZUH_PATH, "logs", "integrations.log")
SPOOL_DIR = os.path.join(WAZUH_PATH, "tmp", "digest")
DEFAULTS = {"window": 300, "max_chars": 3500, "max_agents": 10, "max_packages": 8}
SEVERITY_ORDER = [
    "unknown",
    "low",
    "medium",
    "moderate",
    "high",
    "important",
    "critical",
]


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(
                "%s custom-digest: %s\n" % (time.strftime("%Y/%m/%d %H:%M:%S"), msg)
            )
    except OSError:
        pass


def load_options(args):
    opts = dict(DEFAULTS)
    for arg in args[4:]:
        if arg.endswith("options"):
            try:
                with open(arg) as f:
                    given = json.load(f)
                opts.update({k: v for k, v in given.items() if k in DEFAULTS})
            except (OSError, ValueError, AttributeError):
                log("options file unreadable, using defaults")
    return opts


def summarize(alert):
    """Reduce a Wazuh alert to the fields the digest needs."""
    rule = alert.get("rule", {})
    item = {
        "id": str(rule.get("id", "?")),
        "level": int(rule.get("level", 0)),
        "desc": rule.get("description", "N/A"),
        "groups": rule.get("groups", []),
        "agent": alert.get("agent", {}).get("name") or "manager",
    }
    vuln = alert.get("data", {}).get("vulnerability")
    if isinstance(vuln, dict):
        item["vuln"] = {
            "cve": vuln.get("cve"),
            "severity": str(vuln.get("severity", "unknown")),
            "package": (vuln.get("package") or {}).get("name"),
        }
    return item


def spool_append(item, spool_dir=SPOOL_DIR):
    """Append one line to the spool under a lock; return True if a flusher must start."""
    os.makedirs(spool_dir, mode=0o700, exist_ok=True)
    line = json.dumps(item, separators=(",", ":")) + "\n"
    with open(os.path.join(spool_dir, "spool.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(os.path.join(spool_dir, "spool.jsonl"), "a") as f:
            f.write(line)
        return not flusher_running(spool_dir)


def flusher_running(spool_dir):
    with open(os.path.join(spool_dir, "flush.lock"), "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        return False


def take_spool(spool_dir):
    """Move the spool away under its lock and return its items.

    A batch left behind by a flusher that died is read as well.
    """
    src = os.path.join(spool_dir, "spool.jsonl")
    dst = os.path.join(spool_dir, "batch.jsonl")
    with open(os.path.join(spool_dir, "spool.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if os.path.exists(src):
            if os.path.exists(dst):
                with open(src) as s, open(dst, "a") as d:
                    d.write(s.read())
                os.unlink(src)
            else:
                os.rename(src, dst)
    items = []
    try:
        with open(dst) as f:
            for line in f:
                try:
                    items.append(json.loads(line))
                except ValueError:
                    pass
    except FileNotFoundError:
        return items
    os.unlink(dst)
    return items


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def trim(names, limit):
    names = sorted(set(names))
    if len(names) > limit:
        return ", ".join(names[:limit]) + " +%d" % (len(names) - limit)
    return ", ".join(names)


def severity_rank(name):
    low = name.lower()
    return SEVERITY_ORDER.index(low) if low in SEVERITY_ORDER else 0


def group_items(items):
    groups = {}
    for it in items:
        if "vuln" in it:
            key = (it["id"], it["level"], "vuln")
        else:
            key = (it["id"], it["level"], it["desc"])
        groups.setdefault(key, []).append(it)
    return sorted(groups.items(), key=lambda kv: (-kv[0][1], -len(kv[1]), kv[0][0]))


def format_group(key, items, opts):
    rid, level, desc = key
    agents = trim([i["agent"] for i in items], opts["max_agents"])
    if desc == "vuln":
        vulns = [i["vuln"] for i in items]
        cves = {v["cve"] for v in vulns if v["cve"]}
        worst = max((v["severity"] for v in vulns), key=severity_rank)
        pkgs = trim([v["package"] for v in vulns if v["package"]], opts["max_packages"])
        head = "*Vulnerabilities* (rule %s, level %d): %s, %s, highest severity %s" % (
            rid,
            level,
            plural(len(items), "alert"),
            plural(len(cves), "CVE"),
            worst,
        )
        return "%s\nPackages: %s\nAgents: %s" % (head, pkgs or "-", agents)
    head = "*%s* (rule %s, level %d): %s" % (
        desc,
        rid,
        level,
        plural(len(items), "alert"),
    )
    return "%s\nAgents: %s" % (head, agents)


def build_message(items, opts):
    groups = group_items(items)
    window = int(opts["window"])
    title = "*Wazuh: %s in %s* (collected over %d min)" % (
        plural(len(items), "alert"),
        plural(len(groups), "group"),
        max(1, window // 60),
    )
    parts, size = [title], len(title)
    for n, (key, grp) in enumerate(groups):
        text = format_group(key, grp, opts)[:800]
        rest = groups[n:]
        footer = "... and %d more groups (%d alerts)" % (
            len(rest),
            sum(len(g) for _, g in rest),
        )
        reserve = 0 if n == len(groups) - 1 else len(footer) + 2
        if size + len(text) + 2 + reserve > opts["max_chars"]:
            parts.append(footer)
            break
        parts.append(text)
        size += len(text) + 2
    return {"text": "\n\n".join(parts)}


def ssl_context():
    """Wazuh's bundled Python has no default CA path; use its certifi bundle."""
    try:
        import certifi
    except ImportError:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=certifi.where())


def post(url, payload):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10, context=ssl_context()) as resp:
        return resp.status


def send(url, payload, retry_wait=5):
    """One retry; failures are logged without the URL and the digest is dropped."""
    for attempt in (1, 2):
        try:
            post(url, payload)
            return True
        except Exception as exc:
            code = getattr(exc, "code", None) or type(exc).__name__
            log("post failed (attempt %d): %s" % (attempt, code))
            if attempt == 1:
                time.sleep(retry_wait)
    log("digest dropped")
    return False


def flush_loop(url, opts, spool_dir=SPOOL_DIR):
    with open(os.path.join(spool_dir, "flush.lock"), "a") as flush:
        try:
            fcntl.flock(flush, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return  # another flusher is running
        while True:
            time.sleep(opts["window"])
            items = take_spool(spool_dir)
            if items:
                send(url, build_message(items, opts))
            with open(os.path.join(spool_dir, "spool.lock"), "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                try:
                    pending = (
                        os.path.getsize(os.path.join(spool_dir, "spool.jsonl")) > 0
                    )
                except FileNotFoundError:
                    pending = False
                if not pending:
                    # release the flush lock under the spool lock,
                    # so the next appender starts a new flusher
                    fcntl.flock(flush, fcntl.LOCK_UN)
                    return


def detach():
    """Double fork; True in the detached child, False in the original process."""
    if os.fork():
        return False
    os.setsid()
    if os.fork():
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in range(3):
        os.dup2(devnull, fd)
    os.closerange(3, 1024)
    return True


def main(args):
    if len(args) < 4:
        log("wrong arguments")
        return 2
    try:
        with open(args[1]) as f:
            alert = json.load(f)
    except (OSError, ValueError):
        log("alert file unreadable")
        return 6
    opts = load_options(args)
    if spool_append(summarize(alert)):
        if detach():
            try:
                flush_loop(args[3], opts)
            except Exception as exc:
                log("flusher failed: %s" % type(exc).__name__)
            os._exit(0)
        os.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
