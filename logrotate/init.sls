### Logrotate rules
/etc/logrotate.d/rsyslog:
  file.managed:
    - source: salt://logrotate/rsyslog

{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}
{% if 'docker' in role %}
# Traefik access log: kept on the host (not under /var/log, which graylog-sidecar ships)
/srv/docker/traefik/logs:
  file.directory:
    - user: root
    - group: root
    - mode: "0700"
    - makedirs: True

/etc/logrotate.d/traefik-access:
  file.managed:
    - source: salt://logrotate/traefik-access
{% endif %}
