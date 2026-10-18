###
# Komodo Periphery
###

{%- from "komodo-periphery/map.jinja" import komodo with context %}
{%- if komodo.periphery.enabled %}
{%- set periphery = komodo.periphery %}
{%- set core_public_key = salt['pillar.get']('komodo:core_public_key', '') %}
{%- set addresses = salt['pillar.get']('netbox:interfaces:' ~ periphery.interface ~ ':ipaddresses', []) %}
{%- set arch = {'amd64': 'x86_64', 'arm64': 'aarch64'}.get(grains.osarch, grains.osarch) %}

{%- if not core_public_key or addresses | length == 0 %}
komodo-periphery-config-missing:
  test.fail_without_changes:
    - name: "komodo periphery enabled, but pillar komodo:core_public_key or an address on {{ periphery.interface }} is missing"
{%- else %}

komodo-periphery-git:
  pkg.installed:
    - name: git

komodo-periphery-binary:
  file.managed:
    - name: /usr/local/bin/periphery
    - source: https://github.com/moghtech/komodo/releases/download/v{{ periphery.version }}/periphery-{{ arch }}
    - source_hash: sha256={{ periphery.sha256[arch] }}
    - user: root
    - group: root
    - mode: "0755"

komodo-periphery-config:
  file.managed:
    - name: /etc/komodo/periphery.config.toml
    - source: salt://komodo-periphery/files/periphery.config.toml.jinja
    - template: jinja
    - makedirs: True
    - user: root
    - group: root
    - mode: "0600"
    - context:
        bind_ip: "{{ addresses[0]['address'].split('/')[0] }}"
        core_public_key: "{{ core_public_key }}"

komodo-periphery-service-file:
  file.managed:
    - name: /etc/systemd/system/periphery.service
    - source: salt://komodo-periphery/files/periphery.service
    - user: root
    - group: root
    - mode: "0644"

komodo-periphery-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: komodo-periphery-service-file

komodo-periphery-service:
  service.running:
    - name: periphery
    - enable: True
    - require:
      - pkg: komodo-periphery-git
      - cmd: komodo-periphery-daemon-reload
    - watch:
      - file: komodo-periphery-binary
      - file: komodo-periphery-config
      - file: komodo-periphery-service-file
{%- endif %}
{%- endif %}
