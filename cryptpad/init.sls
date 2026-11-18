###
# CryptPad config.js (docker05), mounted by the Komodo stack docker05/cryptpad. The admin account keys come from pillar
# cryptpad:admin_keys_lines (the verbatim lines inside `adminKeys: [ ... ]`; master: /srv/docker/salt/pillar/komodo-secrets/docker05.sls,
# never in Git). infra.js is in the stack directory. A config change needs a container restart (Komodo).
###

{%- if not salt['pillar.get']('cryptpad:admin_keys_lines', '') %}
cryptpad-config-missing:
  test.fail_without_changes:
    - name: "pillar cryptpad:admin_keys_lines is missing"
{%- else %}
cryptpad-config:
  file.managed:
    - name: /srv/docker/cryptpad/data/config.js
    - source: salt://cryptpad/config.js.j2
    - template: jinja
    - user: 4001
    - group: 4001
    - mode: "0644"
    - show_changes: False
{%- endif %}
