#!/bin/bash

which nebula-cert 1>/dev/null || echo "nebula-cert not installed" || exit 2
which jq 1>/dev/null || echo "jq not installed" || exit 2

echo "This script will delete the current nebula CA and related host certificates to create new ones. Press [ENTER] to continue"
read

# Regenerate CA with validity of 10 years
rm ca.crt ca.key
nebula-cert ca -duration 87600h -name "Freifunk Muenchen Nebula CA G2"

for i in *.ffmuc.net.crt; do

  _data=$(nebula-cert print -json -path $i)
  name=$(echo $_data | jq '.details.name' | tr -d '"')
  groups=$(echo $_data | jq '.details.groups' | tr -cd 'a-z,')
  ip=$(echo $_data | jq '.details.ips[0]' | tr -d '"')

  rm -v $name.crt $name.key

  echo $ip - $name - $groups
  nebula-cert sign -name "$name" -ip "$ip" -groups "$groups"
done
