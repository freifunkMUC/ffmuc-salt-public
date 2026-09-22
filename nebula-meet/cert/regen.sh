#!/bin/bash
#
# Regenerate the Nebula CA and re-sign every host certificate in this
# directory, preserving each host's name, IP and groups.
#
set -uo pipefail

# These must be real guards: the previous form was
#   which jq 1>/dev/null || echo "jq not installed" || exit 2
# where `exit 2` can never run, because `echo` always succeeds. A missing jq
# therefore got past the check and the script went on to delete the CA before
# failing - leaving no way to re-sign the host certificates.
for tool in nebula-cert jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not installed" >&2
        exit 2
    fi
done

shopt -s nullglob
certs=(*.ffmuc.net.crt)
if [ ${#certs[@]} -eq 0 ]; then
    echo "No *.ffmuc.net.crt files here - run this from the cert directory." >&2
    exit 2
fi

echo "This script will delete the current nebula CA and related host certificates to create new ones. Press [ENTER] to continue"
read -r

# Regenerate CA with validity of 5 years
rm ca.crt ca.key
nebula-cert ca -duration 43800h -name "Freifunk Muenchen Meet Nebula CA G3"

for i in "${certs[@]}"; do

  _data=$(nebula-cert print -json -path "$i")
  name=$(echo "$_data" | jq '.details.name' | tr -d '"')
  groups=$(echo "$_data" | jq '.details.groups' | tr -cd 'a-z,')
  ip=$(echo "$_data" | jq '.details.ips[0]' | tr -d '"')

  rm -v "$name.crt" "$name.key"

  echo "$ip - $name - $groups"
  nebula-cert sign -name "$name" -ip "$ip" -groups "$groups"
done
