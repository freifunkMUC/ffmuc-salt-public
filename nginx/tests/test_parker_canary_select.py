"""Tests for nginx/parker-canary-select.py. Synthetic data only.

Run: python3 -m unittest discover -s nginx/tests
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "select", os.path.join(os.path.dirname(HERE), "parker-canary-select.py")
)
sel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sel)


def node(node_id, branch="stable", image="img-a", release="v2026.10.1", **kw):
    n = {
        "node_id": node_id,
        "is_online": True,
        "addresses": ["2001:678:ed0:109::%s" % node_id, "fe80::1"],
        "firmware": {"release": release, "image_name": image},
        "autoupdater": {"enabled": True, "branch": branch},
    }
    n.update(kw)
    return n


class SelectTest(unittest.TestCase):
    def run_select(self, nodes, links=(), size=25, listed=()):
        data = {"nodes": nodes, "links": list(links)}
        return sel.select(data, {"img-a"}, set(listed), size)

    def test_filters(self):
        nodes = [
            node("1"),
            node("2"),
            node("3"),
            node("4", image="img-b"),
            node("5", release="v2022.5.8"),
            node("6", release="v2026.11.2-parker11"),
            node("7", addresses=["fd62::1"]),
            node("8", branch="parker"),
            node("9", autoupdater={"enabled": False, "branch": "stable"}),
            node("10"),
            node("11", hostname="Technopark_I_GW"),
            node(
                "12",
                firmware={
                    "release": "v2026.10.1",
                    "image_name": "img-a",
                    "target": "x86",
                },
            ),
            node("13", hostname="ffmuc-gwangju"),
            node("gw", is_gateway=True),
        ]
        links = [
            {"type": "wifi", "source": "2", "target": "3"},
            {"type": "vpn", "source": "1", "target": "gw"},
        ]
        eligible, skipped, batch = self.run_select(nodes, links, listed={"10"})
        self.assertEqual([n["node_id"] for n in batch], ["1", "13"])
        self.assertEqual(len(eligible), 2)
        self.assertEqual(skipped["gateway-like hostname"], 1)
        self.assertEqual(skipped["VM image"], 1)
        self.assertEqual(skipped["mesh neighbours"], 2)
        self.assertEqual(skipped["no Parker image"], 1)
        self.assertEqual(skipped["no upgrade path"], 1)
        self.assertEqual(skipped["no public IPv6"], 1)
        self.assertEqual(skipped["branch parker"], 1)
        self.assertEqual(skipped["autoupdater off"], 1)
        self.assertEqual(skipped["already listed"], 1)

    def test_guard_keeps_three_classic(self):
        nodes = [node(str(i), branch="testing") for i in range(5)]
        _, _, batch = self.run_select(nodes)
        self.assertEqual(len(batch), 2)

    def test_round_robin(self):
        nodes = [node("b%d" % i) for i in range(5)]
        nodes += [node("e%d" % i, branch="experimental") for i in range(5)]
        _, _, batch = self.run_select(nodes, size=4)
        branches = [n["autoupdater"]["branch"] for n in batch]
        self.assertEqual(branches, ["experimental", "stable", "experimental", "stable"])

    def test_yaml(self):
        out = sel.to_yaml([node("1", hostname="a", model="M")])
        self.assertIn('  - node_id: "1"\n    hostname: "a"\n', out)
        self.assertIn('    addresses:\n      - "2001:678:ed0:109::1"\n', out)


if __name__ == "__main__":
    unittest.main()
