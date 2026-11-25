#!/bin/bash
# Offline helper (not deployed): generate one DNSCrypt resolver certificate set (XChaCha20 + XSalsa20)
# signed with the provider key. Output: <outdir>/<serial>.json, a dict for the NetBox
# config context dnsdist:dnscrypt_certs (merge its entries into the existing dict; mode 0600, never print it).
# The provider key stays off all hosts; it is only read from the path given here.
# Usage: dnscrypt-certs.sh <providerPrivate.key> <outdir> [validity-days=365]
# Needs docker; the container runs with --network none.
# Serial = YYYYMMDD of today (SERIAL=... overrides); it must rise with every new set.
set -euo pipefail
key=$(readlink -f "${1:?provider key file}"); out=$(readlink -f "${2:?output dir}"); days=${3:-365}
image=powerdns/dnsdist-21:2.1.3
serial=${SERIAL:-$(date +%Y%m%d)}; from=$(( $(date +%s) - 3600 )); until=$(( from + days * 86400 ))
umask 077; mkdir -p "$out"
cat > "$out/gen.lua" <<LUA
generateDNSCryptCertificate("/in/provider.key", "/out/$serial-xchacha.cert", "/out/$serial-xchacha.key", $serial, $from, $until, DNSCryptExchangeVersion.VERSION2)
generateDNSCryptCertificate("/in/provider.key", "/out/$serial-xsalsa.cert", "/out/$serial-xsalsa.key", $serial, $from, $until, DNSCryptExchangeVersion.VERSION1)
LUA
docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint dnsdist \
  -v "$key:/in/provider.key:ro" -v "$out:/out" "$image" --check-config -C /out/gen.lua >/dev/null
{
  echo '{'
  for v in xchacha xsalsa; do
    printf '  "%s-%s": {"cert": "%s", "key": "%s"}%s\n' "$serial" "$v" \
      "$(base64 -w0 "$out/$serial-$v.cert")" "$(base64 -w0 "$out/$serial-$v.key")" "$([ $v = xchacha ] && echo ,)"
  done
  echo '}'
} > "$out/$serial.json"
rm -f "$out/gen.lua" "$out"/*.cert "$out"/*.key
echo "wrote $out/$serial.json (serial $serial, valid $days days)"
