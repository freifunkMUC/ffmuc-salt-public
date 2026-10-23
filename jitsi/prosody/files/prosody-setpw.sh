#!/bin/bash
# Sets a Prosody account password read from stdin (one line) unless the stored credentials already match it in the
# form the configured auth provider reads (internal_hashed: SCRAM keys; internal_plain: plaintext).
# usage: prosody-setpw [--force] [--backend internal_hashed|internal_plain] [--config FILE] JID ACCOUNT_DAT
# Prints a salt stateful line; the password never appears on a command line or in the comment.
# Known limitation: the .dat parser is a regex, not Lua; a stored plaintext with ", ; , or a backslash escape does not
# match and is always set again (harmless: one passwd too many). The rotation uses 40 alphanumeric characters.
set -euo pipefail

force=0
backend=internal_hashed
cfg=()
while [ $# -gt 2 ]; do
  case $1 in
    --force) force=1; shift ;;
    --backend) backend=$2; shift 2 ;;
    --config) cfg=(--config "$2"); shift 2 ;;
    *) echo "changed=no comment='unknown option $1'"; exit 2 ;;
  esac
done
[ $# -eq 2 ] || { echo "changed=no comment='usage: prosody-setpw [--force] [--backend NAME] [--config FILE] JID ACCOUNT_DAT'"; exit 2; }
case $backend in internal_hashed|internal_plain) ;; *) echo "changed=no comment='unknown backend $backend'"; exit 2 ;; esac
jid=$1
dat=$2

pw=
IFS= read -r pw || true
[ -n "$pw" ] || { echo "changed=no comment='$jid: no password on stdin'"; exit 2; }
[ -e "$dat" ] || { echo "changed=no comment='$jid: no account file'"; exit 1; }

# exit 0: SCRAM keys match, no plaintext, enabled; 4: same but disabled (adduser under internal_plain
# leaves disabled = true, which only internal_hashed honours); 3: stored plaintext matches; 1: no match
check() {
  python3 -I -c '
import hashlib, hmac, re, sys
pw = sys.stdin.readline().rstrip("\n").encode()
f = dict(re.findall(r"\[\"(\w+)\"\]\s*=\s*\"?([^\";,\n]*)\"?", open(sys.argv[1]).read()))
if "password" in f:
    sys.exit(3 if f["password"].encode() == pw else 1)
if not {"stored_key", "server_key", "salt", "iteration_count"} <= f.keys():
    sys.exit(1)
for alg in ("sha1", "sha256"):
    sp = hashlib.pbkdf2_hmac(alg, pw, f["salt"].encode(), int(f["iteration_count"]))
    ck = hmac.new(sp, b"Client Key", alg).digest()
    sk = hmac.new(sp, b"Server Key", alg).hexdigest()
    if hashlib.new(alg, ck).hexdigest() == f["stored_key"].lower() and sk == f["server_key"].lower():
        sys.exit(4 if f.get("disabled") == "true" else 0)
sys.exit(1)
' "$dat" <<<"$pw"
}

# first line of prosodyctl's output for the state comment: prompts dropped, quotes stripped, the password
# masked should it ever appear (passwd reads it from stdin without echo, so it should not)
first_line() {
  local line
  line=$(grep -v -i -E '^\s*$|password:' <<<"$1" | head -1 | tr -d "'\"" | cut -c1-100) || true
  printf '%s' "${line//"$pw"/<masked>}"
}

# every prosodyctl call is bounded: the admin shell has no timeout of its own and exits 0 when the server hangs up
pctl() { timeout 20 prosodyctl "${cfg[@]}" "$@"; }

# prosodyctl passwd/shell talk to the running server through the admin socket since 13.0; right after a restart
# (rollback-config switches the backend and restarts Prosody) it can take a few seconds to appear. The probe counts
# only with a version number in the answer, since the exit code alone does not prove a connection.
socket_ok=0
wait_socket() {
  local end=$((SECONDS + 30)) v
  [ "$socket_ok" = 1 ] && return 0
  while [ "$SECONDS" -lt "$end" ]; do
    v=$(pctl shell 'server:version()' 2>&1) && grep -qE '[0-9]+\.[0-9]+' <<<"$v" && { socket_ok=1; return 0; }
    sleep 2
  done
  return 1
}
no_socket() { echo "changed=no comment='$jid: Prosody admin socket not reachable after 30 s${1:-}'"; exit 1; }

rc=0
check || rc=$?
# rc that already matches what the backend reads: 0 for internal_hashed (4 only needs user:enable), 3 for
# internal_plain (a hashed record is unreadable there and must be rewritten)
if [ "$backend" = internal_plain ]; then ok=3; else ok=0; fi
if [ "$force" = 0 ] && [ "$rc" = "$ok" ]; then
  echo "changed=no comment='$jid: unchanged (${backend#internal_})'"
  exit 0
fi

msg=
if [ "$force" = 1 ] || [ "$rc" != 4 ] || [ "$backend" = internal_plain ]; then
  wait_socket || no_socket ", nothing changed"
  out=$(printf '%s\n%s\n' "$pw" "$pw" | pctl passwd "$jid" 2>&1) || msg=$(first_line "$out")
fi

rc=0
check || rc=$?
if [ "$rc" = 4 ] && [ "$backend" = internal_hashed ]; then
  wait_socket || no_socket ", account stays disabled"
  out=$(pctl shell "user:enable(\"$jid\")" 2>&1) || msg=$(first_line "$out")
  rc=0
  check || rc=$?
fi
case $backend:$rc in
  internal_hashed:0) echo "changed=yes comment='$jid: password set (hashed)'" ;;
  internal_hashed:3) echo "changed=yes comment='$jid: password set as plaintext although the config names internal_hashed (Prosody not restarted?)'" ;;
  internal_plain:3) echo "changed=yes comment='$jid: password set (plaintext)'" ;;
  internal_hashed:4) echo "changed=no comment='$jid: password matches, account still disabled (user:enable failed${msg:+: $msg})'"; exit 1 ;;
  internal_plain:[04]) echo "changed=no comment='$jid: stored hashed, unreadable for internal_plain (Prosody not restarted?)'"; exit 1 ;;
  *) echo "changed=no comment='$jid: prosodyctl passwd failed${msg:+: $msg}'"; exit 1 ;;
esac
