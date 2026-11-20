#!/bin/bash
# Runs before wazuh-control start (cont-init 2-manager). Puts the secrets from the environment into files the
# manager reads; nothing secret is in the image or in this repository.
set -eu
etc=/var/ossec/etc
umask 077
printf '%s\n' "$AUTHD_PASS" > "$etc/authd.pass"
printf '%s\n%s\n' "$MATRIX_HOOK_URL" "$MATRIX_TOKEN" > "$etc/matrix-hook"
chown root:wazuh "$etc/authd.pass" "$etc/matrix-hook"
chmod 640 "$etc/authd.pass" "$etc/matrix-hook"
# integratord runs custom-matrix as wazuh
chown root:wazuh /var/ossec/integrations/custom-matrix /var/ossec/integrations/custom-matrix.py
chmod 750 /var/ossec/integrations/custom-matrix /var/ossec/integrations/custom-matrix.py
