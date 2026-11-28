# Mounted over openwisp/configuration/custom_django_settings.py (imported last by the image's settings.py).
# Keycloak login through django-allauth's openid_connect provider; the client secret comes from the environment.
import os

# The image imports this file with `import *` while settings.py is still loading: take its lists, change them in place.
from ..settings import CSRF_TRUSTED_ORIGINS, INSTALLED_APPS, SOCIALACCOUNT_PROVIDERS

INSTALLED_APPS.append("allauth.socialaccount.providers.openid_connect")
# Last, after django.contrib.admin: members_admin.py patches the registered OrganizationUser admin in ready().
INSTALLED_APPS.append("openwisp.configuration.members_admin.MembersAdminConfig")
SOCIALACCOUNT_PROVIDERS.update(
    {
        "openid_connect": {
            "APPS": [
                {
                    "provider_id": "keycloak",
                    "name": "FFMUC Keycloak",
                    "client_id": "openwisp",
                    "secret": os.environ.get("OIDC_CLIENT_SECRET", ""),
                    "settings": {
                        "server_url": os.environ.get(
                            "OIDC_SERVER_URL",
                            "https://keycloak.ffmuc.net/realms/chat/.well-known/openid-configuration",
                        ),
                        "oauth_pkce_enabled": True,
                    },
                }
            ]
        }
    }
)
# TLS ends at Traefik; without these allauth builds http:// redirect URIs.
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https"
# Only members of the Keycloak group `openwisp` get in (oidc_gate.py).
SOCIALACCOUNT_ADAPTER = "openwisp.configuration.oidc_gate.GroupGateAdapter"
# The login page has no provider button: /accounts/oidc/keycloak/login/ starts the flow with a plain GET.
SOCIALACCOUNT_LOGIN_ON_GET = True
# The image scopes both cookies to .ffmuc.net; host-only keeps the admin session away from other ffmuc.net names.
SESSION_COOKIE_DOMAIN = None
CSRF_COOKIE_DOMAIN = None
# Break-glass login on the overlay name (Traefik); the public names come from DASHBOARD_DOMAIN/API_DOMAIN.
# New list: the image's CSRF_TRUSTED_ORIGINS is the same object as CORS_ALLOWED_ORIGINS.
CSRF_TRUSTED_ORIGINS = [*CSRF_TRUSTED_ORIGINS, "https://openwisp.ov.ffmuc.net"]
