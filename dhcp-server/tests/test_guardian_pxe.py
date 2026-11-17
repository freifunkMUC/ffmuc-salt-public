"""Render checks for the guardian PXE templates and netbox_vms.get_vm_install_data.

Synthetic data only. Run: python3 -m unittest discover -s dhcp-server/tests
"""

import importlib.util
import ipaddress
import json
import os
import sys
import types
import unittest

import jinja2

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
ROOT = os.path.dirname(SRC)

CTX = {
    "enabled": True,
    "interfaces": ["eth0"],
    "subnets": [
        {"subnet": "198.51.100.0/24", "pool": "198.51.100.10 - 198.51.100.99"},
        {
            "subnet": "192.0.2.32/27",
            "pool": "192.0.2.55 - 192.0.2.61",
            "routers": "192.0.2.33",
            "dns": "192.0.2.1, 192.0.2.2",
            "next_server": "192.0.2.33",
            "boot_file": "netboot.xyz.kpxe",
        },
    ],
    "pxe": {"enabled": True, "install_hosts": ["vm1.example.test"]},
}

VM = {
    "name": "vm1.example.test",
    "primary_ip4": "192.0.2.50/27",
    "interfaces": [
        {"name": "uplink", "mac": "02:00:00:00:00:02", "addresses": ["203.0.113.5/27"]},
        {"name": "mgmt", "mac": "02:00:00:00:00:01", "addresses": ["192.0.2.50/27"]},
    ],
}


class Raised(Exception):
    pass


def _raise(msg):
    raise Raised(msg)


def render(path, ctx, **extra):
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(ROOT), extensions=["jinja2.ext.do"]
    )
    env.globals["raise"] = _raise
    salt = {
        "config.get": lambda key, default=None: (
            ctx if key.endswith(":dhcp_guardian") else default
        ),
        "network.ip_in_subnet": lambda ip, net: ipaddress.ip_address(ip)
        in ipaddress.ip_network(net),
    }
    return env.get_template(path).render(salt=salt, **extra)


def pxe_map(ctx):
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(ROOT), extensions=["jinja2.ext.do"]
    )
    tpl = env.from_string(
        "{% from 'dhcp-server/pxe/map.jinja' import pxe with context %}{{ pxe | tojson }}"
    )
    salt = {"config.get": lambda key, default=None: ctx}
    return json.loads(tpl.render(salt=salt))


class PxeTemplateTest(unittest.TestCase):
    def test_map(self):
        pxe = pxe_map(CTX)
        self.assertTrue(pxe["enabled"])
        self.assertEqual(pxe["address"], "192.0.2.33")
        self.assertEqual(pxe["subnet"], "192.0.2.32/27")
        self.assertEqual(pxe["url"], "http://192.0.2.33")
        self.assertEqual(pxe["iso"], "ubuntu-26.04.1-live-server-amd64.iso")
        off = dict(CTX, pxe={"enabled": False})
        self.assertFalse(pxe_map(off)["enabled"])
        self.assertFalse(pxe_map(dict(CTX, enabled=False))["enabled"])
        self.assertFalse(
            pxe_map({k: v for k, v in CTX.items() if k != "pxe"})["enabled"]
        )

    def test_kea_class(self):
        c = json.loads(render("dhcp-server/kea-dhcp4-guardian.conf.jinja", CTX))
        self.assertEqual(
            c["Dhcp4"]["client-classes"],
            [
                {
                    "name": "ipxe",
                    "test": "substring(option[77].hex,0,4) == 'iPXE'",
                    "boot-file-name": "http://192.0.2.33/boot.ipxe",
                },
                {
                    "name": "legacy-pxe",
                    "test": "not member('ipxe')",
                    "next-server": "192.0.2.33",
                    "boot-file-name": "netboot.xyz.kpxe",
                },
            ],
        )
        # the classes set the boot file, not the subnet
        self.assertNotIn("boot-file-name", c["Dhcp4"]["subnet4"][1])
        off = json.loads(
            render("dhcp-server/kea-dhcp4-guardian.conf.jinja", dict(CTX, pxe={}))
        )
        self.assertEqual(off["Dhcp4"]["client-classes"], [])
        self.assertEqual(
            off["Dhcp4"]["subnet4"][1]["boot-file-name"], "netboot.xyz.kpxe"
        )

    def test_ipxe(self):
        pxe = pxe_map(CTX)
        boot = render("dhcp-server/pxe/boot.ipxe.jinja", CTX, pxe=pxe)
        self.assertIn(
            "chain --autofree http://192.0.2.33/ipxe/${mac:hexhyp}.ipxe || goto menu",
            boot,
        )
        self.assertIn("tftp://192.0.2.33/netboot.xyz.kpxe", boot)
        host = render(
            "dhcp-server/pxe/host.ipxe.jinja", CTX, pxe=pxe, host="vm1.example.test"
        )
        self.assertIn(
            "url=${base}/ubuntu-26.04.1-live-server-amd64.iso autoinstall", host
        )
        self.assertIn(
            "ds=nocloud-net;s=http://192.0.2.33/autoinstall/vm1.example.test/", host
        )
        self.assertIn("console=tty0 console=ttyS0,115200\n", host)

    def user_data(self, vm):
        out = render(
            "dhcp-server/pxe/user-data.jinja",
            CTX,
            pxe=pxe_map(CTX),
            host="vm1.example.test",
            vm=vm,
            salt_version="3008.5",
            keys='environment="SSH_USER=a" ssh-ed25519 AAAA a\n',
        )
        first, body = out.split("\n", 1)
        self.assertEqual(first, "#cloud-config")
        return json.loads(body)["autoinstall"]

    def test_user_data(self):
        ai = self.user_data(VM)
        eth = ai["network"]["ethernets"]
        self.assertEqual(eth["mgmt"]["match"], {"macaddress": "02:00:00:00:00:01"})
        self.assertEqual(eth["mgmt"]["set-name"], "mgmt")
        self.assertEqual(eth["mgmt"]["addresses"], ["192.0.2.50/27"])
        self.assertEqual(
            eth["mgmt"]["routes"], [{"to": "default", "via": "192.0.2.33"}]
        )
        self.assertEqual(
            eth["mgmt"]["nameservers"]["addresses"], ["192.0.2.1", "192.0.2.2"]
        )
        # only the mgmt interface gets an address; salt sets up the rest
        self.assertNotIn("addresses", eth["uplink"])
        self.assertTrue(eth["uplink"]["optional"])
        cmds = "\n".join(ai["late-commands"])
        self.assertIn("'vm1.example.test' 'saltmaster.in.ffmuc.net'", cmds)
        self.assertIn("startup_states: highstate", cmds)
        self.assertIn("salt-minion=3008.5 salt-common=3008.5", cmds)
        self.assertIn("tcp_keepalive_idle: 30", cmds)
        self.assertIn("127.0.1.1 vm1.example.test vm1/", cmds)
        self.assertIn('GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"', cmds)
        self.assertEqual(ai["shutdown"], "reboot")
        ud = ai["user-data"]
        self.assertEqual(ud["fqdn"], "vm1.example.test")
        self.assertEqual(ud["write_files"][0]["path"], "/root/.ssh/authorized_keys")
        self.assertFalse(ai["ssh"]["allow-pw"])

    def test_user_data_wrong_subnet(self):
        with self.assertRaises(Raised):
            self.user_data(dict(VM, primary_ip4="203.0.113.5/27"))


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def raise_for_status(self):
        pass

    def json(self):
        return self.data


class NetboxModuleTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        exc = types.ModuleType("salt.exceptions")
        exc.CommandExecutionError = type("CommandExecutionError", (Exception,), {})
        responses = {
            "virtualization/virtual-machines/": {
                "results": [
                    {
                        "id": 7,
                        "name": "vm1.example.test",
                        "primary_ip4": {"address": "192.0.2.50/27"},
                    }
                ]
            },
            "ipam/ip-addresses/": {
                "results": [
                    {"address": "192.0.2.50/27", "assigned_object_id": 1},
                    {"address": "2001:db8::1/64", "assigned_object_id": 2},
                ]
            },
            "virtualization/interfaces/": {
                "results": [
                    {"id": 2, "name": "uplink", "mac_address": "02:00:00:00:00:02"},
                    {
                        "id": 1,
                        "name": "mgmt",
                        "primary_mac_address": {"mac_address": "02:00:00:00:00:0A"},
                    },
                    {"id": 3, "name": "dummy0", "mac_address": None},
                ]
            },
        }

        def get(url, headers, timeout):
            self.calls.append(url)
            path = url.split("/api/", 1)[1].split("?")[0]
            return FakeResponse(responses[path])

        req = types.ModuleType("requests")
        req.get = get
        self.mods = {
            "salt": types.ModuleType("salt"),
            "salt.exceptions": exc,
            "requests": req,
        }
        self.saved = {k: sys.modules.get(k) for k in self.mods}
        sys.modules.update(self.mods)
        spec = importlib.util.spec_from_file_location(
            "netbox_vms", os.path.join(ROOT, "_modules", "netbox_vms.py")
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v

    def test_install_data(self):
        d = self.mod.get_vm_install_data(
            "https://nb.example.test/api", "t", "vm1.example.test"
        )
        self.assertEqual(d["primary_ip4"], "192.0.2.50/27")
        self.assertEqual(
            d["interfaces"],
            [
                {"name": "dummy0", "mac": None, "addresses": []},
                {
                    "name": "mgmt",
                    "mac": "02:00:00:00:00:0a",
                    "addresses": ["192.0.2.50/27"],
                },
                {
                    "name": "uplink",
                    "mac": "02:00:00:00:00:02",
                    "addresses": ["2001:db8::1/64"],
                },
            ],
        )
        self.assertIn("virtual_machine_id=7", self.calls[1])


if __name__ == "__main__":
    unittest.main()
