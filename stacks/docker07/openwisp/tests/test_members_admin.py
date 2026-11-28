import importlib.util
import os
import sys
import types
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
WIDE = object()
USERS = types.SimpleNamespace(filter=unittest.mock.Mock(return_value=WIDE))
ADMIN = types.SimpleNamespace(site=types.SimpleNamespace(_registry={}))
for name, attrs in {
    "django": {},
    "django.apps": {"AppConfig": type("AppConfig", (), {})},
    "django.contrib": {"admin": ADMIN},
    "django.contrib.admin": {"site": ADMIN.site},
    "django.contrib.auth": {
        "get_user_model": lambda: types.SimpleNamespace(objects=USERS)
    },
    "swapper": {"load_model": lambda app, model: model},
}.items():
    sys.modules.setdefault(name, types.SimpleNamespace(**attrs))
spec = importlib.util.spec_from_file_location(
    "members_admin", os.path.join(HERE, "..", "config", "members_admin.py")
)
members = importlib.util.module_from_spec(spec)
spec.loader.exec_module(members)


class Base:
    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        return ("base", db_field.name, kwargs)


class Upstream(Base):
    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        if db_field.name == "user" and not request.user.is_superuser:
            kwargs["queryset"] = "narrow"
        return super().formfield_for_foreignkey(db_field, request, **kwargs)

    def _check_user(self, request, queryset):
        self.checked = queryset


members.patch(Upstream)


def call(field, superuser):
    admin_obj = Upstream()
    request = types.SimpleNamespace(user=types.SimpleNamespace(is_superuser=superuser))
    result = admin_obj.formfield_for_foreignkey(
        types.SimpleNamespace(name=field), request
    )
    return admin_obj, result


class Patched(unittest.TestCase):
    def test_member_filter(self):
        members.members_queryset()
        USERS.filter.assert_called_with(
            is_active=True, is_staff=True, is_superuser=False
        )

    def test_non_superuser_gets_wide_queryset_and_check(self):
        admin_obj, result = call("user", False)
        self.assertEqual(result, ("base", "user", {"queryset": WIDE}))
        self.assertIs(admin_obj.checked, WIDE)

    def test_superuser_untouched(self):
        admin_obj, result = call("user", True)
        self.assertEqual(result, ("base", "user", {}))
        self.assertFalse(hasattr(admin_obj, "checked"))

    def test_other_fields_delegated(self):
        admin_obj, result = call("organization", False)
        self.assertEqual(result, ("base", "organization", {}))
        self.assertFalse(hasattr(admin_obj, "checked"))


class Ready(unittest.TestCase):
    def test_patches_registered_class(self):
        class Registered(Upstream):
            pass

        key = "OrganizationUser"
        ADMIN.site._registry[key] = Registered()
        cfg = members.MembersAdminConfig.__new__(members.MembersAdminConfig)
        cfg.ready()
        self.assertIn("formfield_for_foreignkey", vars(Registered))


if __name__ == "__main__":
    unittest.main()
