"""Tests for parker_gateway_stats.py. Synthetic data only.

Run: python3 -m unittest discover -s telegraf/tests
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "parker_gateway_stats",
    os.path.join(os.path.dirname(HERE), "files", "parker_gateway_stats.py"),
)
pgs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pgs)

PROTOCOLS = """BIRD 2.18 ready.
Access restricted
Name       Proto      Table      State  Since         Info
device1    Device     ---        up     2026-11-17
vlan102_v4 BGP        ---        up     2026-11-17    Established
  Description:    Uplink
  BGP state:          Established
    Neighbor address: 192.0.2.1
  Channel ipv4
    State:          UP
    Routes:         1 imported, 1 exported, 1 preferred
    Route change stats:     received   rejected   filtered    ignored   accepted
ibgp_pgw02 BGP        ---        up     11:56:39.921  Established
  Channel ipv4
    Routes:         2 imported, 1 filtered, 3 exported, 2 preferred
  Channel ipv6
    Routes:         4 imported, 5 exported, 4 preferred
vlan102_v6 BGP        ---        start  11:56:39.921  Active        Socket: Connection refused
parker_bfd BFD        ---        up     2026-11-17
"""

BFD = """BIRD 2.18 ready.
Access restricted
parker_bfd:
IP address                Interface  State      Since         Interval  Timeout
fe80::78                  vlan1002   Up         11:56:35.883    0.300    0.900
fe80::79                  vlan1002   Down       2026-11-17      1.000    0.000
"""

KEY_A = "a" * 43 + "="
KEY_B = "b" * 43 + "="
KEY_C = "c" * 43 + "="
KEY_D = "d" * 43 + "="


class ParkerGatewayStatsTest(unittest.TestCase):
    def test_protocols(self):
        protos = {p["name"]: p for p in pgs.parse_protocols(PROTOCOLS)}
        self.assertEqual(
            set(protos),
            {"device1", "vlan102_v4", "ibgp_pgw02", "vlan102_v6", "parker_bfd"},
        )
        self.assertEqual(protos["vlan102_v4"]["info"], "Established")
        self.assertEqual(
            protos["vlan102_v6"]["info"], "Active Socket: Connection refused"
        )
        self.assertEqual(
            protos["ibgp_pgw02"]["channels"],
            {
                "ipv4": {"imported": 2, "filtered": 1, "exported": 3, "preferred": 2},
                "ipv6": {"imported": 4, "exported": 5, "preferred": 4},
            },
        )

    def test_bird_lines(self):
        lines = pgs.bird_lines(PROTOCOLS, BFD)
        self.assertEqual(lines[0], "bird_daemon up=1i")
        self.assertIn(
            "bird_protocol,protocol=vlan102_v4,proto=BGP up=1i,established=1i,"
            'state="up",info="Established"',
            lines,
        )
        self.assertIn(
            "bird_protocol,protocol=vlan102_v6,proto=BGP up=0i,established=0i,"
            'state="start",info="Active Socket: Connection refused"',
            lines,
        )
        self.assertIn(
            "bird_channel,protocol=vlan102_v4,channel=ipv4 imported=1i,exported=1i,preferred=1i",
            lines,
        )
        self.assertIn(
            "bird_bfd_session,protocol=parker_bfd,interface=vlan1002,neighbor=fe80::78 "
            'up=1i,state="Up",interval=0.3,timeout=0.9',
            lines,
        )
        self.assertIn(
            "bird_bfd_session,protocol=parker_bfd,interface=vlan1002,neighbor=fe80::79 "
            'up=0i,state="Down",interval=1.0,timeout=0.0',
            lines,
        )

    def test_bird_down(self):
        self.assertEqual(pgs.bird_lines(None, None), ["bird_daemon up=0i"])

    def test_wireguard_counts_without_keys(self):
        now = 1_000_000
        output = (
            f"{KEY_A}\t{now - 30}\n{KEY_B}\t{now - 600}\n"
            f"{KEY_C}\t{now - 3600}\n{KEY_D}\t0\n"
        )
        lines = pgs.wireguard_lines(output, now)
        self.assertEqual(
            lines,
            [
                "wireguard_peers,interface=wg-nodes peers=4i,handshake_3m=1i,"
                "handshake_15m=2i,handshake_never=1i"
            ],
        )
        for key in (KEY_A, KEY_B, KEY_C, KEY_D):
            self.assertNotIn(key[:10], lines[0])
        self.assertEqual(pgs.wireguard_lines(None, now), [])

    def test_xpgw_counters(self):
        nft_json = (
            '{"nftables": [{"metainfo": {"version": "1.1.6"}}, '
            '{"counter": {"family": "inet", "name": "uplink_to_partner", '
            '"table": "parker_stats", "handle": 2, "packets": 5, "bytes": 700}}, '
            '{"counter": {"family": "inet", "name": "partner_to_nodes", '
            '"table": "parker_stats", "handle": 3, "packets": 7, "bytes": 900}}, '
            '{"counter": {"family": "inet", "name": "other", '
            '"table": "parker_stats", "handle": 4, "packets": 1, "bytes": 1}}]}'
        )
        counters = pgs.nft_counters(nft_json)
        self.assertEqual(
            pgs.xpgw_lines(counters),
            [
                "parker_xpgw_traffic,direction=partner_to_nodes bytes=900i,packets=7i",
                "parker_xpgw_traffic,direction=uplink_to_partner bytes=700i,packets=5i",
            ],
        )
        self.assertEqual(pgs.nat64_source_lines(counters), [])
        self.assertEqual(pgs.nft_counters(None), {})
        self.assertEqual(pgs.nft_counters("not json"), {})

    def test_nat64_source_counters(self):
        nft_json = (
            '{"nftables": [{"metainfo": {"version": "1.1.6"}}, '
            '{"counter": {"family": "inet", "name": "nat64_node_clat_to_nat64", '
            '"table": "parker_stats", "handle": 5, "packets": 3, "bytes": 300}}, '
            '{"counter": {"family": "inet", "name": "nat64_client_to_nat64", '
            '"table": "parker_stats", "handle": 6, "packets": 4, "bytes": 400}}, '
            '{"counter": {"family": "inet", "name": "nat64_node_clat_from_nat64", '
            '"table": "parker_stats", "handle": 7, "packets": 5, "bytes": 500}}, '
            '{"counter": {"family": "inet", "name": "nat64_client_from_nat64", '
            '"table": "parker_stats", "handle": 8, "packets": 6, "bytes": 600}}, '
            '{"counter": {"family": "inet", "name": "uplink_to_partner", '
            '"table": "parker_stats", "handle": 2, "packets": 1, "bytes": 1}}]}'
        )
        self.assertEqual(
            pgs.nat64_source_lines(pgs.nft_counters(nft_json)),
            [
                "parker_nat64_source,source=client,direction=from_nat64 bytes=600i,packets=6i",
                "parker_nat64_source,source=client,direction=to_nat64 bytes=400i,packets=4i",
                "parker_nat64_source,source=node_clat,direction=from_nat64 bytes=500i,packets=5i",
                "parker_nat64_source,source=node_clat,direction=to_nat64 bytes=300i,packets=3i",
            ],
        )

    def test_jool_lines(self):
        stats = (
            "Stat,Value\nJSTAT_RECEIVED6,685\nJSTAT_RECEIVED4,837\nJSTAT_SUCCESS,1517\n"
            "JSTAT_BIB_ENTRIES,294\nJSTAT_SESSIONS,300\nJSTAT_POOL4_MISMATCH,0\n"
            "JSTAT_SESSION_NOT_FOUND,736\nJSTAT64_TTL,3\nJSTAT_PKT_TOO_BIG,35\n"
            "JSTAT_ICMP4ERR_SUCCESS,35\nJSTAT_JOOLD_PKT_SENT,9\n"
        )
        # session and BIB rows include client addresses: the script must only count them
        session = (
            "2001:db8::1#40000,64:ff9b::c000:201#443,10.80.64.1#2001,192.0.2.1#443,ESTABLISHED,01:59:00\n"
            * 3
        )
        bib = "2001:db8::1#40000,10.80.64.1#2001,0\n" * 2
        pool4 = (
            "0,TCP,10.80.64.1,2000,64999,1024,0\n0,TCP,10.80.64.2,2000,2999,1024,0\n"
        )
        lines = pgs.jool_lines(
            stats, {"tcp": (session, bib, pool4), "udp": ("", "", None)}
        )
        self.assertEqual(
            lines,
            [
                "jool_daemon up=1i",
                "jool_stats received6=685i,received4=837i,success=1517i,bib_entries=294i,"
                "sessions=300i,icmp4err_success=35i",
                "jool_drop,reason=64_TTL packets=3i",
                "jool_drop,reason=PKT_TOO_BIG packets=35i",
                "jool_drop,reason=SESSION_NOT_FOUND packets=736i",
                "jool_protocol,protocol=tcp sessions=3i,bib=2i,pool4_ports=64000i",
                "jool_protocol,protocol=udp sessions=0i,bib=0i",
            ],
        )
        for secret in ("2001:db8", "192.0.2.1", "40000", "10.80.64.1"):
            self.assertNotIn(secret, "\n".join(lines))
        self.assertEqual(pgs.jool_lines(None, {}), ["jool_daemon up=0i"])

    def test_escape(self):
        self.assertEqual(pgs.escape_tag("a b,c=d"), "a\\ b\\,c\\=d")
        self.assertEqual(pgs.escape_str('x"y'), '"x\\"y"')


if __name__ == "__main__":
    unittest.main()
