#!/bin/bash
# Scans the images of running containers for fixable HIGH/CRITICAL vulnerabilities (no secret scanning).
# Writes /var/lib/ffmuc-trivy/report.json (counts per image, last report only); check_ffmuc_trivy reads it.
# Cache: vulnerability DB about 1 GB, Java DB about 700 MB. If docker or a DB download fails, the old report stays
# and the script exits non-zero, so the report goes stale (WARNING after 9 days).
set -uo pipefail
D=/var/lib/ffmuc-trivy
export TRIVY_CACHE_DIR=/var/cache/ffmuc-trivy
# trivy saves each image with docker save into TMPDIR; /tmp is tmpfs and counts against MemoryMax
export TMPDIR=$TRIVY_CACHE_DIR/tmp
mkdir -p "$TMPDIR"
T=$(mktemp -d)
trap 'rm -rf "$T"; rm -rf "${TMPDIR:?}"/*' EXIT
docker info >/dev/null 2>&1 || { echo "docker not reachable" >&2; exit 1; }
for o in --download-db-only --download-java-db-only; do
  trivy image --quiet --no-progress --skip-version-check "$o" || { echo "trivy $o failed" >&2; exit 1; }
done
scan() {
  trivy image --quiet --no-progress --skip-version-check --scanners vuln --severity HIGH,CRITICAL \
    --skip-db-update --skip-java-db-update --ignore-unfixed --format json --output "$T/r.json" "$1" 2>"$T/err" \
    && jq -c --arg n "$2" '{image: $n,
      critical: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length),
      high: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length)}' "$T/r.json" >> "$T/images.ndjson"
}
errors=0
: > "$T/images.ndjson"
# unique image IDs of running containers, with the first tag for display
for id in $(docker ps -q | xargs -r docker inspect --format '{{.Image}}' | sort -u); do
  name=$(docker image inspect --format '{{if .RepoTags}}{{index .RepoTags 0}}{{else}}{{.Id}}{{end}}' "$id" 2>/dev/null || echo "$id")
  # one retry per image
  scan "$id" "$name" || scan "$id" "$name" || {
    errors=$((errors + 1))
    echo "scan of $name failed: $(tail -n 1 "$T/err")" >&2
  }
done
jq -s --argjson t "$(date +%s)" --argjson e "$errors" '{generated: $t, errors: $e, images: .}' "$T/images.ndjson" > "$D/report.json.new" \
  && mv "$D/report.json.new" "$D/report.json" && chmod 0644 "$D/report.json"
