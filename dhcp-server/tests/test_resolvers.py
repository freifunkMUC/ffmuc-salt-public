"""Render checks: gateway clients get the anycast resolvers (DHCPv4 and RDNSS),
the resolver of the own site first. See ddr_resolvers4/6 in certs/ddr_cert.jinja.

Synthetic data only. Run: python3 -m unittest discover -s dhcp-server/tests
"""

import ipaddress
import json
import os
import re
import unittest

import jinja2

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

VIE = ["5.1.66.255", "185.150.99.255"]
MUC = ["185.150.99.255", "5.1.66.255"]
VIE6 = ["2001:678:e68:f000::", "2001:678:ed0:f000::"]
MUC6 = ["2001:678:ed0:f000::", "2001:678:e68:f000::"]


def ip_in_subnet(address, cidr):
    """Like Salt: a network with host bits set never matches."""
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError:
        return False
    return ipaddress.ip_address(address) in network


def render(path, ipv4):
    """Render a gateway template for a node with the IPv4 addresses ipv4."""
    prefix = "10.80.136.0/21"
    bridge = [{"address": "2001:678:e68:101::2/64", "family": {"value": 6}}]
    config = {
        "netbox:config_context:sites": {"x": ["muc_nord"]},
        "netbox:interfaces": {"br-muc_nord": {"ipaddresses": bridge}},
        "netbox:interfaces:br-muc_nord:ipaddresses": bridge,
    }

    def convert_cidr(cidr):
        net = ipaddress.ip_network(cidr)
        return {
            "network": str(net.network_address),
            "netmask": str(net.netmask),
            "broadcast": str(net.broadcast_address),
        }

    salt = {
        "config.get": lambda key, default=None: config.get(key, default),
        "pillar.get": lambda key, default=None: config.get(key, default),
        "grains.get": lambda key, default=None: ipv4 if key == "ipv4" else default,
        "site_prefixes.get_site_prefixes": lambda *args: {
            "muc_nord": {"prefix": prefix}
        },
        "network.convert_cidr": convert_cidr,
        "network.ip_in_subnet": ip_in_subnet,
        "network.calc_net": lambda cidr: str(ipaddress.ip_network(cidr, strict=False)),
    }
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(REPO), extensions=["jinja2.ext.do"]
    )
    env.filters["regex_replace"] = lambda value, pattern, repl: re.sub(
        pattern, repl, value
    )
    grains = {"id": "gw01.in.ffmuc.net", "ipv4": ipv4}
    return env.get_template(path).render(salt=salt, grains=grains, pillar={})


GW_VIE = ["127.0.0.1", "10.80.136.5", "5.1.66.3"]
GW_MUC = ["127.0.0.1", "10.80.136.5", "185.150.99.1"]
# The webfrontends have the anycast addresses themselves: they do not count
NO_SITE = ["127.0.0.1", "10.80.136.5", "185.150.99.255"]


def kea_options(ipv4):
    cfg = json.loads(render("dhcp-server/kea-dhcp4.conf.jinja", ipv4))
    options = cfg["Dhcp4"]["shared-networks"][0]["subnet4"][0]["option-data"]
    return {o["name"]: o["data"] for o in options}


class KeaTest(unittest.TestCase):
    def test_site_first(self):
        for ipv4, wanted in ((GW_VIE, VIE), (GW_MUC, MUC), (NO_SITE, VIE)):
            options = kea_options(ipv4)
            self.assertEqual(options["domain-name-servers"], ", ".join(wanted))
            self.assertEqual(options["routers"], "10.80.136.5")
            self.assertIn(", " + wanted[0] + ", alpn=dot", options["v4-dnr"])


class DhcpdTest(unittest.TestCase):
    def test_site_first(self):
        for ipv4, wanted in ((GW_VIE, VIE), (GW_MUC, MUC)):
            cfg = render("dhcp-server/dhcpd.conf", ipv4)
            self.assertEqual(
                re.findall(r"option domain-name-servers\s+(.*);", cfg),
                [", ".join(wanted)],
            )
            self.assertRegex(cfg, r"option routers\s+10\.80\.136\.5;")


class RadvdTest(unittest.TestCase):
    def test_site_first(self):
        for ipv4, wanted in ((GW_VIE, VIE6), (GW_MUC, MUC6)):
            cfg = render("radvd/radvd.conf", ipv4)
            self.assertEqual(re.findall(r"RDNSS (.*)", cfg), [" ".join(wanted)])
            self.assertIn("prefix 2001:678:e68:101::/64", cfg)


class AnycastTest(unittest.TestCase):
    def test_same_addresses_as_certificate(self):
        env = jinja2.Environment(
            loader=jinja2.FileSystemLoader(REPO), extensions=["jinja2.ext.do"]
        )
        module = env.get_template("certs/ddr_cert.jinja").make_module(
            {
                "salt": {
                    "config.get": lambda key, default=None: default,
                    "network.ip_in_subnet": ip_in_subnet,
                },
                "grains": {"ipv4": GW_MUC},
            }
        )
        self.assertEqual(
            sorted(module.ddr_resolvers4 + module.ddr_resolvers6),
            sorted(module.ddr_anycast_ips),
        )


if __name__ == "__main__":
    unittest.main()
