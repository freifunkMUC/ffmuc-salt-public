#!/bin/bash
# Creates the 90 day retention policy (new indices get it through ism_template) and attaches it to the indices
# that exist already. Rerun after changing the JSON: it updates the policy.
set -eu
url=https://wazuh.indexer:9200
auth() { printf 'user = "admin:%s"\n' "$ADMIN_PW"; }
cacert=/usr/share/wazuh-indexer/config/certs/root-ca.pem
api() { curl -sS --cacert "$cacert" --config <(auth) -H 'Content-Type: application/json' "$@"; }
if api -o /dev/null -w '%{http_code}' "$url/_plugins/_ism/policies/wazuh-retention" | grep -q 200; then
  seq=$(api "$url/_plugins/_ism/policies/wazuh-retention" | sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p;')
  pri=$(api "$url/_plugins/_ism/policies/wazuh-retention" | sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p;')
  api -X PUT "$url/_plugins/_ism/policies/wazuh-retention?if_seq_no=$seq&if_primary_term=$pri" --data @/policy.json
else
  api -X PUT "$url/_plugins/_ism/policies/wazuh-retention" --data @/policy.json
fi
echo
api -X POST "$url/_plugins/_ism/add/wazuh-alerts-*,wazuh-monitoring-*,wazuh-statistics-*" \
  --data '{"policy_id": "wazuh-retention"}'
echo
