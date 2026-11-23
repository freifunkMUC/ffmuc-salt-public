# Mounted over openwisp/configuration/custom_django_settings.py (imported last by the image's settings.py).
# Keycloak login through django-allauth's openid_connect provider; the client secret comes from the environment.
import os

INSTALLED_APPS += ["allauth.socialaccount.providers.openid_connect"]  # noqa: F821

SOCIALACCOUNT_PROVIDERS = {
    "openid_connect": {
        "APPS": [
            {
                "provider_id": "keycloak",
                "name": "FFMUC Keycloak",
                "client_id": "openwisp",
                "secret": os.environ.get("OIDC_CLIENT_SECRET", ""),
                "settings": {
                    "server_url": "https://keycloak.ffmuc.net/realms/ffmuc/.well-known/openid-configuration",
                    "oauth_pkce_enabled": True,
                },
            }
        ]
    }
}
# TLS ends at Traefik; without these allauth builds http:// redirect URIs.
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https"
# The login page has no provider button: /accounts/oidc/keycloak/login/ starts the flow with a plain GET.
SOCIALACCOUNT_LOGIN_ON_GET = True
