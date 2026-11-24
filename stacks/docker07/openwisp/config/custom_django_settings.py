# Mounted over openwisp/configuration/custom_django_settings.py (imported last by the image's settings.py).
# Keycloak login through django-allauth's openid_connect provider; the client secret comes from the environment.
import os

# The image imports this file with `import *` while settings.py is still loading: take its lists, change them in place.
from ..settings import INSTALLED_APPS, SOCIALACCOUNT_PROVIDERS

INSTALLED_APPS.append("allauth.socialaccount.providers.openid_connect")
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
                            "https://keycloak.ffmuc.net/realms/ffmuc/.well-known/openid-configuration",
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
# The login page has no provider button: /accounts/oidc/keycloak/login/ starts the flow with a plain GET.
SOCIALACCOUNT_LOGIN_ON_GET = True
# The image scopes both cookies to .ffmuc.net; host-only keeps the admin session away from other ffmuc.net names.
SESSION_COOKIE_DOMAIN = None
CSRF_COOKIE_DOMAIN = None
