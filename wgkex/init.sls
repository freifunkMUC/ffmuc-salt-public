{%- if 'nextgen-gateway' in salt['pillar.get']('netbox:role:name') %}

python3-virtualenv:
  pkg.installed

/srv/wgkex:
  file.directory:
    - mode: "0755"
    - user: wgkex
    - group: wgkex

/srv/wgkex/wgkex:
  git.latest:
    - name: https://github.com/freifunkMUC/wgkex.git
    - rev: main
    - target: /srv/wgkex/wgkex
    - user: wgkex

/srv/wgkex/wgkex/venv:
  virtualenv.managed:
    - name: /srv/wgkex/wgkex/venv
    - requirements: /srv/wgkex/wgkex/requirements.txt
    - user: wgkex

/etc/systemd/system/wgkex.service:
  file.managed:
    - source: salt://wgkex/wgkex.service

/etc/wgkex.yaml:
  file.managed:
    - source: salt://wgkex/wgkex.yaml

wgkex-service:
  service.running:
    - name: wgkex
    - enable: True
    - require:
        - file: /etc/wgkex.yaml
    - watch:
        - file: /etc/wgkex.yaml

{% endif %}
