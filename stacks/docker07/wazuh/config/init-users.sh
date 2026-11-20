#!/bin/bash
# Writes /out/internal_users.yml: admin (indexer) and kibanaserver (dashboard) with hashes of the passwords in the
# environment. No demo users.
set -eu
export JAVA_HOME=/usr/share/wazuh-indexer/jdk
hash() { /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -env "$1" 2>/dev/null | tail -n1; }
admin_hash=$(hash ADMIN_PW)
dash_hash=$(hash DASHBOARD_PW)
case "$admin_hash$dash_hash" in *\$2*\$2*) ;; *) echo "hashing failed" >&2; exit 1 ;; esac
umask 077
cat > /out/internal_users.yml <<YAML
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "$admin_hash"
  reserved: true
  backend_roles:
  - "admin"
  description: "Wazuh admin"

kibanaserver:
  hash: "$dash_hash"
  reserved: true
  description: "Wazuh dashboard service user"
YAML
echo "wrote /out/internal_users.yml"
