{%- if 'nextgen-gateway' in salt['pillar.get']('netbox:role:name') %}

python3-pyroute2:
  pkg.installed

/srv/wgkex:
  git.latest:
    - name: https://github.com/freifunkMUC/wgkex
    - target: /srv/wgkex
    - rev: main
/etc/systemd/system/wgkex.service:
  file.managed:
    - source: salt://wgkex/wgkex.service

/etc/systemd/system/wgkex-ffdon.service:
  file.managed:
    - source: salt://wgkex/wgkex-ffdon.service

/etc/wgkex.yaml:
  file.managed:
    - source: salt://wgkex/wgkex.yaml

/etc/wgkex-ffdon.yaml:
  file.managed:
    - source: salt://wgkex/wgkex-ffdon.yaml

wgkex-service:
  service.running:
    - name: wgkex
    - enable: True
    - require:
        - file: /etc/wgkex.yaml
    - watch:
        - file: /etc/wgkex.yaml

wgkex-ffdon-service:
  service.dead:
    - name: wgkex-ffdon
    - enable: False
    - require:
        - file: /etc/wgkex-ffdon.yaml
    - watch:
        - file: /etc/wgkex-ffdon.yaml

systemd-reload-wgkex:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/wgkex.service
    - watch_in:
      - service: wgkex-service

systemd-reload-wgkex-ffdon:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/wgkex-ffdon.service
    - watch_in:
      - service: wgkex-ffdon-service

{% endif %}
