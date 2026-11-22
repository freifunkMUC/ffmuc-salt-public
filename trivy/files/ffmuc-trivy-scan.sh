#!/bin/bash
# Scans the images of running containers for fixable HIGH/CRITICAL vulnerabilities (no secret scanning).
# Writes /var/lib/ffmuc-trivy/report.json (counts and fixable CRITICAL CVE IDs per image, last report only);
# check_ffmuc_trivy reads it. "new" = number of (image, CVE) pairs of fixable CRITICALs that were not in the previous
# report (0 without a usable previous report); image = Config.Image of a container using it (digest stripped).
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
      cves: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL") | .VulnerabilityID] | unique),
      high: ([.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length)}' "$T/r.json" >> "$T/images.ndjson"
}
errors=0
: > "$T/images.ndjson"
# image ID and Config.Image of the running containers; one scan per image ID
docker ps -q | xargs -r docker inspect --format '{{.Image}}|{{.Config.Image}}' > "$T/ctrs" || { echo "docker inspect failed" >&2; exit 1; }
cut -d'|' -f1 "$T/ctrs" | sort -u > "$T/ids"
# fd 3, so that docker and trivy in the loop cannot read the list
while read -r id <&3; do
  name=$(awk -F'|' -v id="$id" '$1 == id {print $2; exit}' "$T/ctrs" | sed 's/@sha256:[0-9a-f]*$//')
  case $name in ''|sha256:*) name=$(docker image inspect --format '{{if .RepoTags}}{{index .RepoTags 0}}{{end}}' "$id" 2>/dev/null); [ -n "$name" ] || name=$id;; esac
  # one retry per image
  scan "$id" "$name" || scan "$id" "$name" || {
    errors=$((errors + 1))
    # keep the previous findings of this image so a failed scan does not turn them into "new" later
    [ -s "$D/report.json" ] && jq -c --arg n "$name" '.images[]? | select(.image == $n)' "$D/report.json" >> "$T/images.ndjson"
    echo "scan of $name failed: $(tail -n 1 "$T/err")" >&2
  }
done 3< "$T/ids"
prev=$D/report.json; [ -s "$prev" ] || prev=/dev/null
jq -s --argjson t "$(date +%s)" --argjson e "$errors" --slurpfile p "$prev" '
  def pairs: [.[] | .image as $i | .cves[]? | "\($i) \(.)"] | unique;
  . as $imgs | ($p[0].images // null) as $pi
  | (if ($pi | type) == "array" and ($pi | length) > 0 and all($pi[]; has("cves")) then ($imgs | pairs) - ($pi | pairs) else [] end) as $new
  | {generated: $t, errors: $e, new: ($new | length), images: $imgs}' "$T/images.ndjson" > "$D/report.json.new" \
  && mv "$D/report.json.new" "$D/report.json" && chmod 0644 "$D/report.json"
