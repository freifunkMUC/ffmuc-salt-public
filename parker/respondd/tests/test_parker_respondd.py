"""Tests for parker-respondd.py and the templates that use it.

Synthetic data only. Run: python3 -m unittest discover -s parker/respondd/tests
"""

import importlib.util
import json
import os
import re
import socket
import threading
import tomllib
import unittest
import zlib
from unittest import mock

import jinja2

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(SRC))

spec = importlib.util.spec_from_file_location(
    "parker_respondd", os.path.join(SRC, "parker-respondd.py")
)
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)

CONFIG = {
    "hostname": "pgw09.ext.ffmuc.net",
    "listen": ["::1"],
    "wireguard_interface": "wg-nodes",
    "address_interfaces": ["dummy0"],
    "nodeinfo": {"system": {"site_code": "ffmuc", "domain_code": "ffmuc"}},
}

IP_JSON = {
    ("dummy0", "global"): [{"addr_info": [{"local": "2001:db8::9"}]}],
    ("wg-nodes", "link"): [{"addr_info": [{"local": "fe80::9"}]}],
}


def fake_run(cmd):
    if cmd[0] == "ip":
        return json.dumps(IP_JSON.get((cmd[6], cmd[8]), []))
    if cmd[0] == "wg":
        return "keyA\t1000\nkeyB\t0\nkeyC\t500\n"
    return ""


def inflate(data):
    return json.loads(zlib.decompress(data, -15))


@mock.patch.object(pr, "run", fake_run)
@mock.patch.object(pr.time, "time", lambda: 1100)
class ReplyTest(unittest.TestCase):
    def test_get_all_topics(self):
        r = pr.Respondd(CONFIG)
        data = inflate(r.reply(b"GET nodeinfo statistics neighbours"))
        self.assertEqual(set(data), {"nodeinfo", "statistics", "neighbours"})
        info = data["nodeinfo"]
        self.assertEqual(info["hostname"], "pgw09.ext.ffmuc.net")
        self.assertEqual(info["network"]["addresses"], ["2001:db8::9"])
        self.assertEqual(
            info["network"]["mesh"]["wg-nodes"]["interfaces"]["tunnel"], ["fe80::9"]
        )
        self.assertEqual(info["system"]["domain_code"], "ffmuc")
        self.assertTrue(info["vpn"])
        # yanic joins the topics by node_id
        self.assertEqual(data["statistics"]["node_id"], info["node_id"])
        self.assertEqual(data["neighbours"]["node_id"], info["node_id"])
        self.assertEqual(
            data["statistics"]["wireguard"], {"peers": 3, "active_peers": 1}
        )
        self.assertEqual(data["statistics"]["clients"]["total"], 0)

    def test_node_id_is_stable_unicast_local_mac(self):
        nid = pr.node_id("pgw09.ext.ffmuc.net")
        self.assertEqual(nid, pr.node_id("pgw09.ext.ffmuc.net"))
        self.assertNotEqual(nid, pr.node_id("pgw10.ext.ffmuc.net"))
        self.assertRegex(nid, r"^[0-9a-f]{12}$")
        first = int(nid[:2], 16)
        self.assertEqual(first & 0x03, 0x02)

    def test_single_topic_and_unknown(self):
        r = pr.Respondd(CONFIG)
        self.assertIn("node_id", json.loads(r.reply(b"neighbours")))
        self.assertIsNone(r.reply(b"wireguard"))
        self.assertIsNone(r.reply(b"GET wireguard"))
        self.assertIsNone(r.reply(b""))
        data = inflate(r.reply(b"GET nodeinfo wireguard"))
        self.assertEqual(set(data), {"nodeinfo"})

    def test_udp_round_trip(self):
        r = pr.Respondd(CONFIG)
        server = pr.open_sockets(["::1"], 0)
        port = server[0].getsockname()[1]
        t = threading.Thread(target=pr.serve, args=(r, server, True))
        t.start()
        client = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        client.settimeout(5)
        client.sendto(b"GET nodeinfo statistics neighbours", ("::1", port))
        answer, source = client.recvfrom(8192)
        t.join(5)
        client.close()
        server[0].close()
        self.assertEqual(source[1], port)
        self.assertEqual(inflate(answer)["nodeinfo"]["hostname"], CONFIG["hostname"])


def render(path, grains, pillar, mine):
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(REPO), extensions=["jinja2.ext.do"]
    )
    env.filters["regex_replace"] = lambda s, p, r: re.sub(p, r, s)

    def pillar_get(key, default=None):
        value = pillar
        for part in key.split(":"):
            if not isinstance(value, dict) or part not in value:
                return default
            value = value[part]
        return value

    def mine_get(tgt, fun, tgt_type="glob"):
        if fun == "minion_id":
            return {n: n for n in mine}
        return {tgt: mine[tgt]} if tgt in mine and mine[tgt] is not None else {}

    salt = {
        "pillar.get": pillar_get,
        "grains.get": lambda key, default=None: grains.get(key, default),
        "mine.get": mine_get,
    }
    return env.get_template(path).render(salt=salt, grains=grains)


GRAINS = {"id": "pgw01.in.ffmuc.net", "ip4_interfaces:nebula0": ["10.8.0.1"]}
MINE = {
    "pgw01.in.ffmuc.net": "10.8.0.1/16",
    "pgw02.in.ffmuc.net": "10.8.0.2/16",
    "pgw03.in.ffmuc.net": None,  # no overlay address yet
}
PILLAR = {"netbox": {"site": {"latitude": "48.1", "longitude": "11.5"}}}


class TemplateTest(unittest.TestCase):
    def test_yanic_conf(self):
        conf = tomllib.loads(
            render("parker/yanic/yanic.conf.tmpl", GRAINS, PILLAR, MINE)
        )
        ifaces = conf["respondd"]["interfaces"]
        self.assertEqual(
            ifaces[0],
            {
                "ifname": "lo",
                "ip_address": "::1",
                "send_no_request": True,
                "port": 11001,
            },
        )
        self.assertEqual(ifaces[1]["multicast_address"], "::1")
        # only the other pgws with an overlay address, not this pgw
        self.assertEqual([i["multicast_address"] for i in ifaces[2:]], ["10.8.0.2"])
        self.assertEqual(ifaces[2]["ip_address"], "::")
        names = [f["name"] for f in conf["respondd"]["custom_field"]]
        self.assertEqual(names, ["wireguard_peers", "wireguard_active_peers"])

    def test_yanic_conf_without_nebula(self):
        grains = {"id": "pgw01.in.ffmuc.net"}
        conf = tomllib.loads(
            render("parker/yanic/yanic.conf.tmpl", grains, PILLAR, MINE)
        )
        self.assertEqual(len(conf["respondd"]["interfaces"]), 2)

    def test_respondd_config(self):
        conf = json.loads(
            render("parker/respondd/parker-respondd.json.jinja", GRAINS, PILLAR, MINE)
        )
        self.assertEqual(conf["hostname"], "pgw01.ext.ffmuc.net")
        self.assertEqual(conf["listen"], ["::1", "10.8.0.1"])
        self.assertEqual(
            conf["nodeinfo"]["location"], {"latitude": 48.1, "longitude": 11.5}
        )

    def test_respondd_config_without_nebula_or_location(self):
        conf = json.loads(
            render(
                "parker/respondd/parker-respondd.json.jinja",
                {"id": "pgw01.in.ffmuc.net"},
                {},
                MINE,
            )
        )
        self.assertEqual(conf["listen"], ["::1"])
        self.assertNotIn("location", conf["nodeinfo"])


if __name__ == "__main__":
    unittest.main()
