#
# parker-respondd: respondd answers of this pgw (nodeinfo, statistics, neighbours).
# Listens on ::1 and on the Nebula address only, port 1001. The local yanic and the
# yanic of the other pgws (over Nebula) poll it (parker/yanic/yanic.conf.tmpl).
#
{%- set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'parker-gateway' in role %}

parker-respondd-pkgs:
  pkg.installed:
    - pkgs:
      - python3
      - wireguard-tools
      - iproute2

/usr/local/bin/parker-respondd.py:
  file.managed:
    - source: salt://parker/respondd/parker-respondd.py
    - mode: "0755"

/etc/parker-respondd.json:
  file.managed:
    - source: salt://parker/respondd/parker-respondd.json.jinja
    - template: jinja
    - mode: "0644"

/etc/systemd/system/parker-respondd.service:
  file.managed:
    - source: salt://parker/respondd/parker-respondd.service
    - mode: "0644"

parker-respondd:
  service.running:
    - enable: True
    - require:
      - pkg: parker-respondd-pkgs
    - watch:
      - file: /usr/local/bin/parker-respondd.py
      - file: /etc/parker-respondd.json
      - file: /etc/systemd/system/parker-respondd.service

{% endif %}
