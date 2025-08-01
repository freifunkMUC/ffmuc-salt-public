{% set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'nextgen-gateway' in role or 'parker-gateway' in role %}

{% set user = "wgkex" %}

# Create Groups
group-{{ user }}:
  group.present:
      - name: {{ user }}

# Create User
user-{{ user }}:
  user.present:
    - name: {{ user }}
    - shell: /bin/sh
    - home: /srv/wgkex
    - createhome: True
    - groups:
      - {{ user }}
    - system: False
    - require:
      - group: group-{{ user }}

python3-virtualenv:
  pkg.installed

/srv/wgkex:
  file.directory:
    - mode: "0755"
    - user: wgkex
    - group: wgkex
    - require:
      - user: user-{{ user }}

/srv/wgkex/wgkex-git:
  git.latest:
    - name: https://github.com/freifunkMUC/wgkex.git
    {% if 'nextgen-gateway' in role  %}
    - rev: main
    {% elif 'parker-gateway' in role %}
    - rev: parker
    {% endif %}
    - target: /srv/wgkex/wgkex-git
    - user: wgkex
    - force_reset: True
    - force_fetch: True
    - require:
      - file: /srv/wgkex

/srv/wgkex/wgkex-git/venv:
  virtualenv.managed:
    - name: /srv/wgkex/wgkex-git/venv
    - requirements: /srv/wgkex/wgkex-git/requirements.txt
    - user: wgkex
    - runas: wgkex  {# workaround for https://github.com/saltstack/salt/issues/59088 #}
    - require:
      - git: /srv/wgkex/wgkex-git

/etc/systemd/system/wgkex-broker.service:
  file.managed:
    - source: salt://parker/wgkex/wgkex-broker.service

/etc/systemd/system/wgkex-worker.service:
  file.managed:
    - source: salt://parker/wgkex/wgkex-worker.service


/etc/wgkex.yaml:
  file.managed:
    - source: salt://parker/wgkex/wgkex.yaml.jinja
    - template: jinja

wgkex-service-broker:
  service.running:
    - name: wgkex-broker
    - enable: True
    - require:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex-git
    - watch:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex-git
wgkex-service-worker:
  service.running:
    - name: wgkex-worker
    - enable: True
    - require:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex-git
    - watch:
        - file: /etc/wgkex.yaml
        - git: /srv/wgkex/wgkex-git

{% endif %}
