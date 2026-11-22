import importlib.util
import json
import multiprocessing
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "custom_digest", os.path.join(HERE, "..", "integrations", "custom-digest.py")
)
digest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(digest)

OPTS = dict(digest.DEFAULTS)


def alert(rid=5710, level=10, desc="sshd: attempt", agent="web01", vuln=None):
    a = {"rule": {"id": rid, "level": level, "description": desc, "groups": ["x"]}}
    if agent:
        a["agent"] = {"id": "001", "name": agent}
    if vuln:
        a["data"] = {"vulnerability": vuln}
    return a


def vuln_alert(cve, pkg, agent, sev="High", level=12):
    v = {"cve": cve, "severity": sev, "package": {"name": pkg, "version": "1"}}
    return alert(23504, level, "%s affects %s" % (cve, pkg), agent, v)


def sample_items():
    alerts = [alert(agent="web%02d" % i) for i in range(3)]
    alerts.append(alert(5503, 10, "PAM: user login failed.", "gw01"))
    alerts += [vuln_alert("CVE-2026-%04d" % i, "openssl", "web01") for i in range(6)]
    alerts += [vuln_alert("CVE-2026-9000", "curl", "web02", "Critical", 15)]
    return [digest.summarize(a) for a in alerts]


class Catcher(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.bodies.append(json.loads(body))
        self.send_response(500 if self.server.fail else 200)
        self.end_headers()

    def log_message(self, *args):
        pass


def serve(fail=False):
    srv = HTTPServer(("127.0.0.1", 0), Catcher)
    srv.bodies, srv.fail = [], fail
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d/hook" % srv.server_port


def _append(spool_dir):
    for i in range(50):
        digest.spool_append(digest.summarize(alert(agent="a%d" % i)), spool_dir)


class TestDigest(unittest.TestCase):
    def test_summarize_without_agent_and_with_vuln(self):
        self.assertEqual(digest.summarize(alert(agent=None))["agent"], "manager")
        item = digest.summarize(vuln_alert("CVE-1", "zlib", "a"))
        self.assertEqual(
            item["vuln"], {"cve": "CVE-1", "severity": "High", "package": "zlib"}
        )

    def test_grouping_and_order(self):
        groups = digest.group_items(sample_items())
        keys = [k for k, _ in groups]
        self.assertEqual(len(groups), 4)
        self.assertEqual(keys[0][1], 15)  # highest level first
        self.assertEqual(sorted(len(g) for _, g in groups), [1, 1, 3, 6])

    def test_message_contents(self):
        text = digest.build_message(sample_items(), OPTS)["text"]
        self.assertIn("11 alerts in 4 groups", text)
        self.assertIn("sshd: attempt* (rule 5710, level 10): 3 alerts", text)
        self.assertIn("6 alerts, 6 CVEs, highest severity High", text)
        self.assertIn("Packages: openssl", text)
        self.assertIn("Agents: web00, web01, web02", text)

    def test_agents_and_packages_truncated(self):
        items = [digest.summarize(alert(agent="h%02d" % i)) for i in range(25)]
        text = digest.build_message(items, OPTS)["text"]
        self.assertIn("h09 +15", text)
        vulns = [
            digest.summarize(vuln_alert("CVE-%d" % i, "pkg%02d" % i, "a"))
            for i in range(12)
        ]
        self.assertIn("pkg07 +4", digest.build_message(vulns, OPTS)["text"])

    def test_message_size_limit(self):
        items = [
            digest.summarize(alert(rid=i, desc="rule %d " % i + "x" * 300, agent="a"))
            for i in range(100)
        ]
        text = digest.build_message(items, OPTS)["text"]
        self.assertLessEqual(len(text), OPTS["max_chars"])
        self.assertRegex(text, r"\.\.\. and \d+ more groups \(\d+ alerts\)$")

    def test_spool_locking_parallel_writers(self):
        with tempfile.TemporaryDirectory() as d:
            procs = [
                multiprocessing.Process(target=_append, args=(d,)) for _ in range(6)
            ]
            [p.start() for p in procs]
            [p.join() for p in procs]
            items = digest.take_spool(d)
            self.assertEqual(len(items), 300)
            self.assertEqual(digest.take_spool(d), [])

    def test_spool_append_requests_flusher_only_once(self):
        with tempfile.TemporaryDirectory() as d:
            item = digest.summarize(alert())
            self.assertTrue(digest.spool_append(item, d))
            lock = open(os.path.join(d, "flush.lock"), "a")
            import fcntl

            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertFalse(digest.spool_append(item, d))
            lock.close()

    def test_flush_loop_posts_one_message(self):
        srv, url = serve()
        with tempfile.TemporaryDirectory() as d:
            for it in sample_items():
                digest.spool_append(it, d)
            digest.flush_loop(url, dict(OPTS, window=0.05), d)
            self.assertEqual(len(srv.bodies), 1)
            self.assertIn("text", srv.bodies[0])
            self.assertEqual(digest.take_spool(d), [])
        srv.shutdown()
        srv.server_close()

    def test_send_retries_once_then_drops(self):
        srv, url = serve(fail=True)
        digest.LOG_FILE = os.devnull
        self.assertFalse(digest.send(url, {"text": "x"}, retry_wait=0))
        self.assertEqual(len(srv.bodies), 2)
        srv.shutdown()
        srv.server_close()

    def test_options_file(self):
        with tempfile.NamedTemporaryFile("w", suffix="options", delete=False) as f:
            json.dump({"window": 60, "bogus": 1}, f)
        opts = digest.load_options(["x", "a", "k", "u", f.name])
        os.unlink(f.name)
        self.assertEqual(opts["window"], 60)
        self.assertNotIn("bogus", opts)


if __name__ == "__main__":
    unittest.main()
