"""Tests for the autoupdater redirects in nginx/domains/firmware.ffmuc.net.conf.

The test renders the Salt template and starts a local nginx on 127.0.0.1.
It skips the nginx part if no nginx binary is installed.

Run: python3 -m unittest discover -s nginx/tests
"""

import http.client
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

import jinja2
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(os.path.dirname(HERE), "domains", "firmware.ffmuc.net.conf")
CANARY_FILE = os.path.join(os.path.dirname(HERE), "parker-canary.yaml")
CANARY_ADDRESS = "2001:db8:109::1"
NGINX = shutil.which("nginx") or (
    "/usr/sbin/nginx" if os.path.exists("/usr/sbin/nginx") else None
)

USER_AGENT = "Gluon Autoupdater (using libuclient)"
BRANCHES = ["experimental", "testing", "stable"]
CLASSIC = "gluon-v2025.1.x_v2023.1.x"


def render(nodes=None):
    """Render the template. nodes=None uses nginx/parker-canary.yaml."""
    with open(TEMPLATE) as f:
        text = f.read()
    if nodes is None:
        with open(CANARY_FILE) as f:
            canary = yaml.safe_load(f)
    else:
        canary = {"nodes": nodes}
    # Salt provides import_yaml; plain jinja2 does not
    text = text.replace(
        '{%- import_yaml "nginx/parker-canary.yaml" as parker_canary %}',
        "{%- set parker_canary = canary %}",
    )
    return (
        jinja2.Environment()
        .from_string(text)
        .render(
            canary=canary,
            domain="firmware.ffmuc.net",
            sslListen="SSL_LISTEN",
            sslListen6="SSL_LISTEN6",
        )
    )


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class RenderTest(unittest.TestCase):
    def test_import_line_exists(self):
        with open(TEMPLATE) as f:
            self.assertIn('import_yaml "nginx/parker-canary.yaml"', f.read())

    def test_empty_list(self):
        conf = render([])
        self.assertIn("geo $parkerCanary {\n    default 0;\n}", conf)

    def test_nodes(self):
        conf = render([{"hostname": "a", "addresses": ["2001:db8::1", "2001:db8::2"]}])
        self.assertIn("    2001:db8::1 1; # a\n    2001:db8::2 1; # a\n}", conf)


@unittest.skipUnless(NGINX, "nginx not installed")
class RedirectTest(unittest.TestCase):
    canary = None

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.port = free_port()
        conf = render(cls.canary)
        conf = conf.replace("listen SSL_LISTEN6 ssl default_server;", "")
        conf = conf.replace("SSL_LISTEN ssl default_server", "127.0.0.1:%d" % cls.port)
        conf = re.sub(r"^\s*ssl_certificate.*$", "", conf, flags=re.M)
        conf = conf.replace("/srv/www/firmware.ffmuc.net", cls.tmp)
        conf = conf.replace("/var/log/nginx/", cls.tmp + "/")
        with open(os.path.join(cls.tmp, "site.conf"), "w") as f:
            f.write(conf)
        with open(os.path.join(cls.tmp, "nginx.conf"), "w") as f:
            f.write(
                "pid %(t)s/nginx.pid;\nerror_log %(t)s/error.log;\n"
                "events {}\nhttp {\n"
                "    client_body_temp_path %(t)s;\n"
                "    set_real_ip_from 127.0.0.1;\n"
                "    real_ip_header X-Forwarded-For;\n"
                "    log_format json_normal '$remote_addr';\n"
                "    include %(t)s/site.conf;\n}\n" % {"t": cls.tmp}
            )
        cmd = [NGINX, "-p", cls.tmp, "-c", os.path.join(cls.tmp, "nginx.conf")]
        subprocess.run(cmd + ["-t"], check=True)
        subprocess.run(cmd + ["-g", "daemon on;"], check=True)
        cls.stop = cmd + ["-s", "stop"]
        time.sleep(0.3)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(cls.stop, check=False)
        time.sleep(0.3)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def get(self, path, version=None, agent=USER_AGENT, client="192.0.2.1"):
        headers = {
            "Host": "firmware.ffmuc.net",
            "User-Agent": agent,
            "X-Forwarded-Proto": "https",
            "X-Forwarded-For": client,
        }
        if version:
            headers["X-Firmware-Version"] = version
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        conn.close()
        return resp.status, resp.getheader("Location")

    def assertTarget(self, version, directory, client="192.0.2.1"):
        for branch in BRANCHES:
            path = "/%s/sysupgrade/%s.manifest" % (branch, branch)
            status, location = self.get(path, version, client=client)
            self.assertEqual(status, 302, (version, branch))
            self.assertEqual(
                location,
                "https://firmware.ffmuc.net/%s/%s/sysupgrade/%s.manifest"
                % (directory, branch, branch),
                version,
            )


class RedirectDefaultTest(RedirectTest):
    def test_classic(self):
        self.assertTarget("v2026.11.3", CLASSIC)
        self.assertTarget("v2023.8.1", CLASSIC)
        self.assertTarget("v2026.11.3-next", "gluon-next")
        self.assertTarget("v2026.11.3-main", "gluon-main")

    def test_no_header(self):
        self.assertTarget(None, "gluon-v2021.1.x")

    def test_parker(self):
        self.assertTarget("v2026.11.2-parker11", "gluon-parker")
        self.assertTarget("v2026.11.2-parker12", "gluon-parker")

    def test_parker_next(self):
        self.assertTarget("v2026.11.2-parker-next2", "gluon-parker-next")

    def test_browser_is_not_redirected(self):
        status, _ = self.get("/stable/", "v2026.11.2-parker11", agent="curl")
        self.assertNotEqual(status, 302)

    def test_parker_branch_paths_are_not_redirected(self):
        for path in [
            "/parker/sysupgrade/parker.manifest",
            "/parker-next/sysupgrade/parker_next.manifest",
        ]:
            for version in [
                "v2026.11.2-parker11",
                "v2026.11.2-parker-next2",
                "v2026.11.3",
            ]:
                status, _ = self.get(path, version)
                self.assertNotEqual(status, 302, (path, version))


class RedirectCanaryTest(RedirectTest):
    canary = [{"hostname": "canary", "addresses": [CANARY_ADDRESS]}]

    def test_listed_classic_goes_to_parker(self):
        for version in ["v2026.11.3", "v2023.8.1", "v2024.3.1-next"]:
            self.assertTarget(version, "gluon-parker", client=CANARY_ADDRESS)

    def test_other_classic_stays(self):
        self.assertTarget("v2026.11.3", CLASSIC)
        self.assertTarget("v2026.11.3", CLASSIC, client="2001:db8:109::2")

    def test_listed_without_upgrade_path_stays(self):
        self.assertTarget(None, "gluon-v2021.1.x", client=CANARY_ADDRESS)
        self.assertTarget(
            "v2022.10.1", "gluon-v2023.1.x_v2021.1.x", client=CANARY_ADDRESS
        )
        self.assertTarget("v2026.11.3-next", "gluon-next", client=CANARY_ADDRESS)
        self.assertTarget("v2026.11.3-main", "gluon-main", client=CANARY_ADDRESS)

    def test_listed_parker_next_stays(self):
        self.assertTarget(
            "v2026.11.2-parker-next2", "gluon-parker-next", client=CANARY_ADDRESS
        )


del RedirectTest


if __name__ == "__main__":
    unittest.main()
