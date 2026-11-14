{#- Host firewall for published container ports (docker04-07).
    Docker publishes ports on 0.0.0.0 and bypasses INPUT; only DOCKER-USER can filter them.
    Policy: containers, loopback and the Nebula overlays pass (the Nebula firewall decides there, this includes the
    webfrontends); on any other ingress interface (underlay vlan100x) new connections to published ports are dropped
    unless the source is in allow_sources.
    Per host (NetBox config context docker_user_firewall): enabled (default off), mode log|enforce (default log:
    would-be drops are only logged as "docker-user-drop:"), allow_sources (IPv4 CIDRs, e.g. APs on the underlay).
    Fail-open while Docker restarts, at boot before the unit ran and if the unit fails (the chain is then empty).
    Rollback: set enabled false, highstate (or by hand: systemctl disable --now docker-user-firewall). #}
{%- set cfg = salt['pillar.get']('netbox:config_context:docker_user_firewall', {}) %}
{%- set enabled = cfg.get('enabled', False) %}
{%- set mode = cfg.get('mode', 'log') %}
{%- set allow_sources = cfg.get('allow_sources', []) %}
{%- if mode not in ('log', 'enforce') %}
  {{ salt['test.exception']('docker_user_firewall.mode must be log or enforce, got ' ~ mode) }}
{%- endif %}
{%- for c in allow_sources %}
  {%- if not c is string or not c | regex_match('^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') %}
    {{ salt['test.exception']('docker_user_firewall.allow_sources: not an IPv4 CIDR: ' ~ c) }}
  {%- endif %}
{%- endfor %}

{%- if enabled %}
/usr/local/sbin/docker-user-firewall:
  file.managed:
    - source: salt://docker-user-firewall/files/docker-user-firewall.sh.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0755'
    - context:
        allow_sources: {{ allow_sources }}
        mode: {{ mode }}

docker-user-firewall-unit:
  file.managed:
    - name: /etc/systemd/system/docker-user-firewall.service
    - source: salt://docker-user-firewall/files/docker-user-firewall.service
    - user: root
    - group: root
    - mode: '0644'

docker-user-firewall-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: docker-user-firewall-unit

docker-user-firewall:
  service.running:
    - enable: True
    - watch:
      - file: /usr/local/sbin/docker-user-firewall
      - file: docker-user-firewall-unit
    - require:
      - cmd: docker-user-firewall-daemon-reload
{%- else %}
{#- Disabled: stopping the unit flushes the chain; nothing happens on hosts that never had it. #}
docker-user-firewall:
  service.dead:
    - enable: False
    - onlyif: test -f /etc/systemd/system/docker-user-firewall.service

docker-user-firewall-files-absent:
  file.absent:
    - names:
      - /etc/systemd/system/docker-user-firewall.service
      - /usr/local/sbin/docker-user-firewall
    - require:
      - service: docker-user-firewall

docker-user-firewall-daemon-reload-absent:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: docker-user-firewall-files-absent
{%- endif %}
