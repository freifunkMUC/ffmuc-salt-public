#!/bin/sh
# Runs INSIDE the team OpenLDAP container (docker04, openldap-openldap-1) as root over ldapi (SASL EXTERNAL).
# Keeps the DN-valued "member" of the posixGroups in ou=Groups equal to their memberUid (uid -> DN in ou=Users), so
# that the memberof overlay maintains memberOf on the users. memberUid stays the source of truth for every client.
# Needs the class dnMemberGroup (schema-group-member.ldif) and the root write rule on member/objectClass in slapd.ldif,
# both installed by infra ops/ffmuc-ldap-memberof.sh (phase apply). Called by the wrapper ffmuc-ldap-group-member
# (systemd timer ffmuc-ldap-group-member.timer, every 10 minutes); the wrapper feeds this file in on stdin.
#
# Usage: ffmuc-ldap-group-member.sh check|apply|strip-member|strip-class [-v]
# check         counts per group (agree / add / remove / uid without a person / invalid uid), exit 1 if anything
#               differs. No names are printed.
# apply         the same, then adds or removes only the differing "member" values (and the class where missing).
# strip-member  rollback step 1: deletes "member" on every group (memberof then removes memberOf from the users).
# strip-class   rollback step 2: removes the class dnMemberGroup (only after step 1).
# -v            also prints the LDIF (contains DNs, so never into logs).
# Environment: LDAP_OPTS (default: ldapi + EXTERNAL), BASE (default dc=ffmuc,dc=net), TMPDIR (the container's root
# is read-only and root has no capabilities: /dev/shm).
set -eu
mode=${1:?check|apply|strip-member|strip-class}; shift
verbose=
if [ "${1:-}" = -v ]; then verbose=1; shift; fi
base=${BASE:-dc=ffmuc,dc=net}
LDAP_OPTS=${LDAP_OPTS:--Y EXTERNAL -H ldapi://%2Frun%2Fslapd%2Fldapi -Q}
# shellcheck disable=SC2086
search() { ldapsearch -LLL -o ldif-wrap=no $LDAP_OPTS "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
LC_ALL=C; export LC_ALL

# "key: value" and "key:: base64" lines -> "key<TAB>value"; blank lines stay.
decode() {
  while IFS= read -r l; do
    case $l in
      *::\ *) k=${l%%::*}; v=$(printf %s "${l#*:: }" | base64 -d) ;;
      *:\ *) k=${l%%:*}; v=${l#*: } ;;
      *) echo; continue ;;
    esac
    printf '%s\t%s\n' "$k" "$v"
  done
}
# Case and spaces after commas do not matter in a DN.
norm() { tr '[:upper:]' '[:lower:]' | sed 's/ *, */,/g'; }
b64() { printf %s "$1" | base64 -w0; }
finish() {
  [ -z "$verbose" ] || cat "$work/ldif"
  [ "$diff" = 1 ] || exit 0
  if [ "$mode" = check ]; then exit 1; fi
  # shellcheck disable=SC2086
  ldapmodify $LDAP_OPTS -f "$work/ldif" >/dev/null
  echo applied
}

# Every search goes to a file first and must succeed: a failed or empty search would otherwise look like "no members"
# and delete every member value (sh has no pipefail).
die() { echo "STOP: $*" >&2; exit 3; }
search -b "ou=Groups,$base" -s one '(objectClass=posixGroup)' dn >"$work/groups.raw" || die "group search failed"
decode <"$work/groups.raw" | awk -F'\t' '$1=="dn"{print $2}' >"$work/groups"
[ -s "$work/groups" ] || die "no groups found"
: >"$work/ldif"
diff=0

case $mode in
strip-member | strip-class)
  while IFS= read -r gdn; do
    [ -n "$gdn" ] || continue
    search -b "$gdn" -s base '(objectClass=*)' objectClass member >"$work/g.raw" || die "search of a group failed"
    decode <"$work/g.raw" >"$work/g"
    if [ "$mode" = strip-member ]; then
      n=$(awk -F'\t' '$1=="member"' "$work/g" | grep -c . || true)
      echo "group ${gdn%%,*}: member values $n"
      [ "$n" -gt 0 ] || continue
      printf 'dn:: %s\nchangetype: modify\ndelete: member\n\n' "$(b64 "$gdn")" >>"$work/ldif"
    else
      c=$(awk -F'\t' '$1=="objectClass" && tolower($2)=="dnmembergroup"' "$work/g" | grep -c . || true)
      echo "group ${gdn%%,*}: class dnMemberGroup $c"
      [ "$c" -gt 0 ] || continue
      printf 'dn:: %s\nchangetype: modify\ndelete: objectClass\nobjectClass: dnMemberGroup\n\n' "$(b64 "$gdn")" >>"$work/ldif"
    fi
    diff=1
  done <"$work/groups"
  mode=apply; finish; exit 0 ;;
check | apply) ;;
*) echo "usage: $0 check|apply|strip-member|strip-class [-v]" >&2; exit 2 ;;
esac

# uid <TAB> DN of every person; a uid that occurs twice is dropped (counted as "without a person").
search -b "ou=Users,$base" -s one '(uid=*)' uid >"$work/people.raw" || die "people search failed"
decode <"$work/people.raw" | awk -F'\t' '$1=="dn"{dn=$2} $1=="uid"{print $2 "\t" dn}' >"$work/people.all"
awk -F'\t' '{n[$1]++; d[$1]=$2} END{for(u in n) if(n[u]==1) print u "\t" d[u]}' "$work/people.all" >"$work/people"
[ -s "$work/people" ] || die "no persons found"

while IFS= read -r gdn; do
  [ -n "$gdn" ] || continue
  search -b "$gdn" -s base '(objectClass=*)' objectClass member memberUid >"$work/g.raw" || die "search of a group failed"
  decode <"$work/g.raw" >"$work/g"
  gcn=${gdn%%,*}; gcn=${gcn#cn=}
  : >"$work/want"; : >"$work/cnt"
  awk -F'\t' '$1=="member"{print $2}' "$work/g" | sort -u >"$work/have"
  awk -F'\t' '$1=="memberUid"{print $2}' "$work/g" | sort -u | while IFS= read -r uid; do
    case $uid in
      '' | *[!A-Za-z0-9._-]*) echo bad >>"$work/cnt" ;;
      *) d=$(awk -F'\t' -v u="$uid" '$1==u{print $2}' "$work/people")
         if [ -n "$d" ]; then printf '%s\n' "$d" >>"$work/want"; else echo nop >>"$work/cnt"; fi ;;
    esac
  done
  nop=$(grep -c '^nop$' "$work/cnt" || true); bad=$(grep -c '^bad$' "$work/cnt" || true)
  norm <"$work/want" | sort -u >"$work/want.n"; norm <"$work/have" | sort -u >"$work/have.n"
  : >"$work/add"; : >"$work/del"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$(printf '%s\n' "$d" | norm)
    grep -Fxq -- "$n" "$work/have.n" || printf '%s\n' "$d" >>"$work/add"
  done <"$work/want"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$(printf '%s\n' "$d" | norm)
    grep -Fxq -- "$n" "$work/want.n" || printf '%s\n' "$d" >>"$work/del"
  done <"$work/have"
  nadd=$(grep -c . "$work/add" || true); ndel=$(grep -c . "$work/del" || true)
  agree=$(( $(grep -c . "$work/want.n" || true) - nadd ))
  noclass=1
  if awk -F'\t' '$1=="objectClass" && tolower($2)=="dnmembergroup"{f=1} END{exit !f}' "$work/g"; then noclass=0; fi
  extra=
  [ "$noclass" = 0 ] || extra=", class missing"
  echo "group $gcn: agree $agree, add $nadd, remove $ndel, without person $nop, invalid uid $bad$extra"
  [ "$nadd" -gt 0 ] || [ "$ndel" -gt 0 ] || [ "$noclass" = 1 ] || continue
  diff=1
  if [ "$noclass" = 1 ]; then
    # Own change first: memberof looks at the class the group had before a change, so class and member together
    # would be missed.
    printf 'dn:: %s\nchangetype: modify\nadd: objectClass\nobjectClass: dnMemberGroup\n\n' "$(b64 "$gdn")" >>"$work/ldif"
  fi
  if [ "$nadd" -gt 0 ] || [ "$ndel" -gt 0 ]; then
    printf 'dn:: %s\nchangetype: modify\n' "$(b64 "$gdn")" >>"$work/ldif"
    if [ "$ndel" -gt 0 ]; then
      echo "delete: member" >>"$work/ldif"
      while IFS= read -r d; do printf 'member:: %s\n' "$(b64 "$d")" >>"$work/ldif"; done <"$work/del"
      echo "-" >>"$work/ldif"
    fi
    if [ "$nadd" -gt 0 ]; then
      echo "add: member" >>"$work/ldif"
      while IFS= read -r d; do printf 'member:: %s\n' "$(b64 "$d")" >>"$work/ldif"; done <"$work/add"
      echo "-" >>"$work/ldif"
    fi
    echo >>"$work/ldif"
  fi
done <"$work/groups"
finish
