"""Tests for kea_pool_stats (run: python3 -m unittest discover dhcp-server/tests)."""

import contextlib
import importlib.util
import io
import json
import os
import socket
import tempfile
import threading
import unittest

_PATH = os.path.join(os.path.dirname(__file__), "..", "kea_pool_stats.py")
_SPEC = importlib.util.spec_from_file_location("kea_pool_stats", _PATH)
kps = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(kps)

CONFIG = {
    "shared-networks": [
        {
            "name": "muc_cty",
            "subnet4": [
                {
                    "id": 1,
                    "subnet": "10.80.0.0/24",
                    "pools": [{"pool": "10.80.0.10 - 10.80.0.254"}],
                }
            ],
        },
        {
            "name": "muc_uml",
            "subnet4": [
                {
                    "id": 2,
                    "subnet": "10.81.0.0/24",
                    "pools": [{"pool": "10.81.0.10-10.81.0.254"}],
                }
            ],
        },
    ]
}


def sample(value):
    return [[value, "2026-09-30 12:00:00.000000"]]


STATS = {
    "subnet[1].total-addresses": sample(245),
    "subnet[1].assigned-addresses": sample(49),
    "subnet[1].declined-addresses": sample(0),
    "subnet[2].total-addresses": sample(245),
    "subnet[2].assigned-addresses": sample(210),
    "subnet[2].declined-addresses": sample(5),
}


class BuildReportTest(unittest.TestCase):
    def test_subnets_match_dhcpd_pools_format(self):
        report = kps.build_report(CONFIG, STATS)
        first, second = report["subnets"]
        self.assertEqual(first["location"], "muc_cty")
        self.assertEqual(first["range"], "10.80.0.10 - 10.80.0.254")
        self.assertEqual(first["first_ip"], "10.80.0.10")
        self.assertEqual(first["last_ip"], "10.80.0.254")
        self.assertEqual(
            (first["defined"], first["used"], first["free"]), (245, 49, 196)
        )
        self.assertEqual(first["percent"], 20.0)
        # declined addresses count as touched, not as used
        self.assertEqual((second["used"], second["touched"]), (205, 5))
        self.assertEqual(second["touch_count"], 210)
        self.assertEqual(second["range"], "10.81.0.10 - 10.81.0.254")

    def test_shared_networks_and_summary(self):
        report = kps.build_report(CONFIG, STATS)
        names = [net["location"] for net in report["shared-networks"]]
        self.assertEqual(names, ["muc_cty", "muc_uml"])
        summary = report["summary"]
        self.assertEqual(summary["location"], "All networks")
        self.assertEqual(
            (summary["defined"], summary["used"], summary["touched"]), (490, 254, 5)
        )

    def test_missing_statistics_count_as_zero(self):
        report = kps.build_report(CONFIG, {})
        self.assertEqual(report["summary"]["defined"], 0)
        self.assertEqual(report["summary"]["percent"], 0.0)

    def test_plain_subnets_without_shared_network(self):
        config = {"subnet4": CONFIG["shared-networks"][0]["subnet4"]}
        report = kps.build_report(config, STATS)
        self.assertEqual(report["shared-networks"], [])
        self.assertEqual(report["subnets"][0]["location"], "10.80.0.0/24")

    def test_thresholds_set_status(self):
        report = kps.build_report(CONFIG, STATS, warning=75, critical=80)
        self.assertEqual(
            [s["status"] for s in report["subnets"]], [kps.OK, kps.CRITICAL]
        )
        report = kps.build_report(CONFIG, STATS, warning=75, critical=90)
        self.assertEqual(report["subnets"][1]["status"], kps.WARNING)


class NagiosResultTest(unittest.TestCase):
    def test_worst_status_wins(self):
        report = kps.build_report(CONFIG, STATS, warning=75, critical=80)
        code, line = kps.nagios_result(report)
        self.assertEqual(code, kps.CRITICAL)
        self.assertTrue(line.startswith("CRITICAL: Ranges - crit: 1 warn: 0 ok: 1 |"))
        self.assertIn("'muc_cty'=49;;;0;245", line)

    def test_ok_without_ranges(self):
        code, line = kps.nagios_result(
            kps.build_report({}, {}, warning=75, critical=80)
        )
        self.assertEqual((code, line), (kps.OK, "OK: Ranges - crit: 0 warn: 0 ok: 0"))


class FakeKea:
    """Unix socket server answering like kea-dhcp4's control channel."""

    def __init__(self, responses, split=False):
        self.responses = responses
        self.split = split
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "kea4-ctrl-socket")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                command = json.loads(conn.recv(65536))["command"]
                payload = json.dumps(self.responses[command]).encode()
                if self.split:
                    half = len(payload) // 2
                    conn.sendall(payload[:half])
                    conn.sendall(payload[half:])
                else:
                    conn.sendall(payload)

    def close(self):
        self.server.close()
        self.dir.cleanup()


RESPONSES = {
    "config-get": {"result": 0, "arguments": {"Dhcp4": CONFIG}},
    "statistic-get-all": {"result": 0, "arguments": STATS},
}


class SocketTest(unittest.TestCase):
    def test_reads_split_responses(self):
        kea = FakeKea(RESPONSES, split=True)
        self.addCleanup(kea.close)
        self.assertEqual(kps.kea_command(kea.path, "statistic-get-all"), STATS)

    def test_error_result_raises(self):
        kea = FakeKea({"config-get": {"result": 1, "text": "not allowed"}})
        self.addCleanup(kea.close)
        with self.assertRaisesRegex(RuntimeError, "not allowed"):
            kps.kea_command(kea.path, "config-get")

    def test_main_prints_dhcpd_pools_json(self):
        kea = FakeKea(RESPONSES)
        self.addCleanup(kea.close)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = kps.main(["--socket", kea.path])
        self.assertEqual(code, 0)
        self.assertEqual(
            set(json.loads(out.getvalue())), {"subnets", "shared-networks", "summary"}
        )

    def test_main_nagios_mode(self):
        kea = FakeKea(RESPONSES)
        self.addCleanup(kea.close)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = kps.main(
                ["--socket", kea.path, "--warning", "75", "--critical", "80"]
            )
        self.assertEqual(code, kps.CRITICAL)
        self.assertTrue(out.getvalue().startswith("CRITICAL"))

    def test_main_unknown_without_socket(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = kps.main(["--socket", "/nonexistent/kea", "--critical", "80"])
        self.assertEqual(code, kps.UNKNOWN)
        self.assertTrue(out.getvalue().startswith("UNKNOWN"))


if __name__ == "__main__":
    unittest.main()
