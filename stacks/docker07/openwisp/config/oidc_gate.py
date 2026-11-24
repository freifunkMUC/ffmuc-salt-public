# Mounted next to custom_django_settings.py (dashboard, which serves the login). Keycloak logins need the group `openwisp` in the `groups`
# claim: in realm `chat`, logins through the member broker and self-registrations never run the client's gate flow.
from allauth.core.exceptions import ImmediateHttpResponse
from allauth.socialaccount.adapter import DefaultSocialAccountAdapter
from django.http import HttpResponseForbidden

GROUP = "openwisp"


class GroupGateAdapter(DefaultSocialAccountAdapter):
    def pre_social_login(self, request, sociallogin):
        data = sociallogin.account.extra_data or {}
        groups = set()
        for part in ("userinfo", "id_token"):
            claim = (data.get(part) or {}).get("groups") or []
            groups.update([claim] if isinstance(claim, str) else claim)
        if GROUP not in groups:
            raise ImmediateHttpResponse(
                HttpResponseForbidden(
                    "OpenWISP is for members of the group %s. Ask the FFMUC admins.\n"
                    % GROUP,
                    content_type="text/plain",
                )
            )
        super().pre_social_login(request, sociallogin)
