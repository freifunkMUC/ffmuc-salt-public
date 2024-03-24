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
    - force_reset: True

/srv/wgkex/wgkex/venv:
  virtualenv.managed:
    - name: /srv/wgkex/wgkex/venv
    - requirements: /srv/wgkex/wgkex/requirements.txt
    - user: wgkex
    - runas: wgkex  {# workaround for https://github.com/saltstack/salt/issues/59088 #}

/etc/systemd/system/wgkex.service:
  file.managed:
    - source: salt://wgkex/wgkex.service

/etc/wgkex.yaml:
  file.managed:
    - source: salt://wgkex/wgkex.yaml.jinja
    - template: jinja

wgkex-service:
  service.running:
    - name: wgkex
    - enable: True
    - require:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex
    - watch:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex

{% endif %}
