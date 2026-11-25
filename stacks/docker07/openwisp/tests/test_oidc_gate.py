import importlib.util
import os
import sys
import types
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
for name, attrs in {
    "allauth": {},
    "allauth.core": {},
    "allauth.core.exceptions": {"ImmediateHttpResponse": Exception},
    "allauth.socialaccount": {},
    "allauth.socialaccount.adapter": {"DefaultSocialAccountAdapter": type("Base", (), {"pre_social_login": lambda self, request, sociallogin: None})},
    "django": {},
    "django.http": {"HttpResponseForbidden": lambda *args, **kwargs: None},
}.items():
    sys.modules.setdefault(name, types.SimpleNamespace(**attrs))
spec = importlib.util.spec_from_file_location("oidc_gate", os.path.join(HERE, "..", "config", "oidc_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class Allowed(unittest.TestCase):
    def test_group_name_or_path(self):
        self.assertTrue(gate.allowed({"openwisp"}))
        self.assertTrue(gate.allowed({"/openwisp", "x"}))

    def test_other_groups_refused(self):
        self.assertFalse(gate.allowed(set()))
        self.assertFalse(gate.allowed({"/other", "/other/openwisp", "/openwisp/a", "openwisp2"}))


class FreeSlug(unittest.TestCase):
    def test_sanitized_and_lowercase(self):
        self.assertEqual(gate.free_slug("Max.Muster_01", lambda s: False), "max-muster-01")
        self.assertEqual(gate.free_slug("--A  B--", lambda s: False), "a-b")

    def test_unusable_name(self):
        self.assertEqual(gate.free_slug("+++", lambda s: False), "user")

    def test_suffix_while_taken(self):
        taken = {"max", "max-2"}
        self.assertEqual(gate.free_slug("Max", taken.__contains__), "max-3")


class Login(unittest.TestCase):
    def login(self, groups, existing=True):
        calls = []
        gate.revoke_user = lambda user: calls.append("revoke")
        gate.ensure_personal_org = lambda user: calls.append("ensure")
        user = types.SimpleNamespace(is_staff=True, pk=1 if existing else None)
        account = types.SimpleNamespace(extra_data={"userinfo": {"groups": groups}})
        sociallogin = types.SimpleNamespace(account=account, user=user, is_existing=existing)
        try:
            gate.GroupGateAdapter().pre_social_login(None, sociallogin)
            return calls, False
        except gate.ImmediateHttpResponse:
            return calls, True

    def test_rejected_existing_user_is_revoked_without_org(self):
        self.assertEqual(self.login(["/other"]), (["revoke"], True))

    def test_rejected_new_user_gets_nothing(self):
        self.assertEqual(self.login([], existing=False), ([], True))

    def test_member_gets_personal_org(self):
        self.assertEqual(self.login(["openwisp"]), (["ensure"], False))

    def test_new_user_is_handled_by_save_user(self):
        self.assertEqual(self.login(["openwisp"], existing=False), ([], False))


if __name__ == "__main__":
    unittest.main()
