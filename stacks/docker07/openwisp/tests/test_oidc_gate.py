import importlib.util
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
for name, attrs in {
    "allauth": {},
    "allauth.core": {},
    "allauth.core.exceptions": {"ImmediateHttpResponse": Exception},
    "allauth.socialaccount": {},
    "allauth.socialaccount.adapter": {"DefaultSocialAccountAdapter": object},
    "django": {},
    "django.http": {"HttpResponseForbidden": object},
}.items():
    sys.modules.setdefault(name, types.SimpleNamespace(**attrs))
spec = importlib.util.spec_from_file_location("oidc_gate", os.path.join(HERE, "..", "config", "oidc_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ParseGroups(unittest.TestCase):
    def test_legacy_claim_opens_gate_without_sync(self):
        self.assertEqual(gate.parse_groups({"openwisp"}), (True, False, {}, False))

    def test_other_group_is_refused(self):
        self.assertFalse(gate.parse_groups({"/other", "/other/openwisp"})[0])
        self.assertFalse(gate.parse_groups(set())[0])

    def test_parent_only(self):
        self.assertEqual(gate.parse_groups({"/openwisp"}), (True, True, {}, False))

    def test_subgroup_alone_opens_gate(self):
        self.assertEqual(gate.parse_groups({"/openwisp/muc"}), (True, True, {"muc": False}, False))

    def test_admin_wins_over_member(self):
        for groups in ({"/openwisp/muc", "/openwisp/muc/admin"}, {"/openwisp/muc/admin"}):
            self.assertEqual(gate.parse_groups(groups)[2:], ({"muc": True}, True))

    def test_several_orgs(self):
        self.assertEqual(gate.parse_groups({"/openwisp/a", "/openwisp/b/admin"})[2:], ({"a": False, "b": True}, True))

    def test_ignores_odd_paths(self):
        groups = {"/openwisp", "/openwisp/Bad_Slug", "/openwisp/a/b", "/openwisp/a/admin/x", "/openwisp//admin", "/x/openwisp/a"}
        self.assertEqual(gate.parse_groups(groups)[2:], ({}, False))


if __name__ == "__main__":
    unittest.main()
