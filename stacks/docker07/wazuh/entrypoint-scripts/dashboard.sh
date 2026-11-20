#!/bin/bash
# Upstream /entrypoint.sh plus the OIDC client secret in the keystore (not readable from the config file).
set -eu
ks=/usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore
yes | $ks create --allow-root
add() { printf '%s\n' "$2" | $ks add "$1" --stdin --allow-root; }
add opensearch.username "${DASHBOARD_USERNAME:-kibanaserver}"
add opensearch.password "$DASHBOARD_PASSWORD"
add opensearch_security.openid.client_secret "$OIDC_CLIENT_SECRET"
/wazuh_app_config.sh "${WAZUH_UI_REVISION:-}"
exec /usr/share/wazuh-dashboard/bin/opensearch-dashboards -c /usr/share/wazuh-dashboard/config/opensearch_dashboards.yml
