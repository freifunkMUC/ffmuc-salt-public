# Mounted next to custom_django_settings.py. Org admins may add any OpenWISP member (active staff, no superuser) to their
# organizations; upstream only offers users already in organizations they manage. Needs django.contrib.admin loaded first.
import os

from django.apps import AppConfig
from django.contrib import admin
from django.contrib.auth import get_user_model
from swapper import load_model


def members_queryset():
    return get_user_model().objects.filter(
        is_active=True, is_staff=True, is_superuser=False
    )


def patch(admin_class):
    original = admin_class.formfield_for_foreignkey
    owner = next(
        c for c in admin_class.__mro__ if "formfield_for_foreignkey" in vars(c)
    )

    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        if db_field.name != "user" or request.user.is_superuser:
            return original(self, db_field, request, **kwargs)
        queryset = members_queryset()
        self._check_user(request, queryset)
        kwargs["queryset"] = queryset
        # Skip the upstream override, which would narrow the choices again.
        return super(owner, self).formfield_for_foreignkey(db_field, request, **kwargs)

    admin_class.formfield_for_foreignkey = formfield_for_foreignkey


class MembersAdminConfig(AppConfig):
    name = "openwisp.configuration.members_admin"
    label = "ffmuc_members"
    path = os.path.dirname(os.path.abspath(__file__))

    def ready(self):
        # api/websocket/celery load the same settings; skip quietly where the admin is not registered
        registered = admin.site._registry.get(
            load_model("openwisp_users", "OrganizationUser")
        )
        if registered is not None:
            patch(type(registered))
