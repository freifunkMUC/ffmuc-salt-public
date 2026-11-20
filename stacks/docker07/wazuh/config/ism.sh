#!/bin/bash
# Creates the 90 day retention policy (new indices get it through ism_template) and attaches it to the indices
# that exist already. Rerun after changing the JSON: it updates the policy.
set -eu
url=https://wazuh.indexer:9200
auth() { printf 'user = "admin:%s"\n' "$ADMIN_PW"; }
cacert=/usr/share/wazuh-indexer/config/certs/root-ca.pem
api() { curl -sS --cacert "$cacert" --config <(auth) -H 'Content-Type: application/json' "$@"; }
p=$url/_plugins/_ism/policies/wazuh-retention
code=$(api -o /tmp/policy -w '%{http_code}' "$p")
case $code in
  200) seq=$(sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p' /tmp/policy)
       pri=$(sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p' /tmp/policy)
       q="?if_seq_no=$seq&if_primary_term=$pri" ;;
  404) q= ;;
  *) echo "policy GET: HTTP $code" >&2; exit 1 ;;
esac
code=$(api -o /dev/null -w '%{http_code}' -X PUT "$p$q" --data @/policy.json)
case $code in 200|201) echo "policy PUT: HTTP $code" ;; *) echo "policy PUT: HTTP $code" >&2; exit 1 ;; esac
# Indices that already carry a policy come back as failures; only other reasons count as errors.
code=$(api -o /tmp/add -w '%{http_code}' -X POST "$url/_plugins/_ism/add/wazuh-alerts-*,wazuh-monitoring-*,wazuh-statistics-*" \
  --data '{"policy_id": "wazuh-retention"}')
[ "$code" = 200 ] || { echo "add: HTTP $code" >&2; exit 1; }
had=$(grep -o '"reason":"[^"]*"' /tmp/add | grep -c 'already has a policy' || true)
echo "attached: $(sed -n 's/.*"updated_indices":\([0-9]*\).*/\1/p' /tmp/add), already had a policy: $had"
if grep -o '"reason":"[^"]*"' /tmp/add | grep -v 'already has a policy'; then exit 1; fi
