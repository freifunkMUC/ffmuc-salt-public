#!/bin/bash
# Runs before wazuh-control start (cont-init 2-manager). Puts the secrets from the environment into files the
# manager reads; nothing secret is in the image or in this repository.
set -eu
etc=/var/ossec/etc
umask 077
printf '%s\n' "$AUTHD_PASS" > "$etc/authd.pass"
chown root:wazuh "$etc/authd.pass"
chmod 640 "$etc/authd.pass"
# Mattermost webhook into ossec.conf (copied from the mount when the container is created; a new URL needs a recreate)
shopt -u patsub_replacement 2>/dev/null || true  # bash 5.2: & in the URL stays literal
conf=$(<"$etc/ossec.conf")
printf '%s\n' "${conf//@MATTERMOST_HOOK_URL@/$MATTERMOST_HOOK_URL}" > "$etc/ossec.conf"
