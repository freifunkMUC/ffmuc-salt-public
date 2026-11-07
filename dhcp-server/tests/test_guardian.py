"""Render check for kea-dhcp4-guardian.conf.jinja and tests for dhcpd_to_context.

Synthetic data only. Run: python3 -m unittest discover -s dhcp-server/tests
"""
import importlib.util
import json
import os
import unittest

import jinja2

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)

spec = importlib.util.spec_from_file_location('dhcpd_to_context', os.path.join(SRC, 'dhcpd_to_context.py'))
conv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conv)

DHCPD = """
authoritative;
option domain-name "example.test";
subnet 192.0.2.32 netmask 255.255.255.224 {
  option routers 192.0.2.33;
  option domain-name-servers 192.0.2.1;
  next-server 192.0.2.33;
  filename "boot.kpxe";
  pool {
    default-lease-time 1800;
    max-lease-time 3600;
    range 192.0.2.55 192.0.2.61;
  }
}
subnet 198.51.100.0 netmask 255.255.255.0 {
  option routers 198.51.100.1;
  pool { default-lease-time 1800; max-lease-time 3600; range 198.51.100.10 198.51.100.99; }
}
host a {
  hardware ethernet 02:00:00:00:00:01;
  fixed-address 192.0.2.40;
  option host-name "a-host";
}
"""


def render(ctx):
    env = jinja2.Environment(extensions=['jinja2.ext.do'])
    tpl = env.from_string(open(os.path.join(SRC, 'kea-dhcp4-guardian.conf.jinja')).read())
    salt = {'config.get': lambda key, default=None: ctx.get(key.split(':')[-1], default)}
    return json.loads(tpl.render(salt=salt))['Dhcp4']


class GuardianTest(unittest.TestCase):
    def setUp(self):
        self.ctx = conv.parse(DHCPD, ['eth0'])

    def test_converter(self):
        s = self.ctx['subnets']
        self.assertEqual(self.ctx['domain_name'], 'example.test')
        self.assertEqual((self.ctx['valid_lifetime'], self.ctx['max_valid_lifetime']), (1800, 3600))
        self.assertEqual(s[0]['subnet'], '192.0.2.32/27')
        self.assertEqual(s[0]['pool'], '192.0.2.55 - 192.0.2.61')
        self.assertEqual(s[0]['reservations'], [{'mac': '02:00:00:00:00:01', 'ip': '192.0.2.40', 'hostname': 'a-host'}])
        self.assertNotIn('reservations', s[1])

    def test_template(self):
        c = render({'dhcp_guardian': self.ctx})
        self.assertEqual(c['interfaces-config']['interfaces'], ['eth0'])
        self.assertEqual([s['id'] for s in c['subnet4']], [1, 2])
        self.assertEqual(c['subnet4'][0]['pools'], [{'pool': '192.0.2.55 - 192.0.2.61'}])
        self.assertEqual(c['subnet4'][0]['next-server'], '192.0.2.33')
        self.assertEqual(c['subnet4'][0]['boot-file-name'], 'boot.kpxe')
        self.assertEqual(c['subnet4'][0]['reservations'][0]['hw-address'], '02:00:00:00:00:01')
        self.assertNotIn('boot-file-name', c['subnet4'][1])
        self.assertEqual(c['valid-lifetime'], 1800)
        self.assertEqual(c['option-data'], [{'name': 'domain-name', 'data': 'example.test'}])
        self.assertTrue(c['authoritative'])


if __name__ == '__main__':
    unittest.main()
