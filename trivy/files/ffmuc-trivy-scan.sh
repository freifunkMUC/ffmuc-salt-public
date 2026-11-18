#!/bin/bash
# Scans the images of running containers for fixable HIGH/CRITICAL vulnerabilities (no secret scanning).
# Writes /var/lib/ffmuc-trivy/report.json (counts per image, last report only); check_ffmuc_trivy reads it.
set -uo pipefail
D=/var/lib/ffmuc-trivy
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TRIVY_CACHE_DIR=/var/cache/ffmuc-trivy
mkdir -p "$TRIVY_CACHE_DIR"
errors=0
: > "$T/images.ndjson"
# unique image IDs of running containers, with the first tag for display
for id in $(docker ps -q | xargs -r docker inspect --format '{{.Image}}' | sort -u); do
  name=$(docker image inspect --format '{{if .RepoTags}}{{index .RepoTags 0}}{{else}}{{.Id}}{{end}}' "$id" 2>/dev/null || echo "$id")
  if trivy image --quiet --no-progress --skip-version-check --scanners vuln --severity HIGH,CRITICAL \
       --ignore-unfixed --format json --output "$T/r.json" "$id" 2>"$T/err"; then
    jq -c --arg n "$name" '{image: $n,
      critical: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length),
      high: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length)}' "$T/r.json" >> "$T/images.ndjson" || errors=$((errors + 1))
  else
    errors=$((errors + 1))
    echo "scan of $name failed: $(tail -n 1 "$T/err")" >&2
  fi
done
jq -s --argjson t "$(date +%s)" --argjson e "$errors" '{generated: $t, errors: $e, images: .}' "$T/images.ndjson" > "$D/report.json.new" \
  && mv "$D/report.json.new" "$D/report.json" && chmod 0644 "$D/report.json"
