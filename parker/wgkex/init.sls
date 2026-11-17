{% set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'nextgen-gateway' in role or 'parker-gateway' in role %}

{% set user = "wgkex" %}
{#- Worker release; keep it equal to wgkex/init.sls and the broker image (stacks/docker0[4-7]/wgkex). #}
{# renovate: datasource=github-releases depName=freifunkMUC/wgkex #}
{% set wgkex_version = 'v0.6.0' %}

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
    - rev: {{ salt['pillar.get']('wgkex:rev', wgkex_version) }}
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

{#- The Parker broker is the classic wgkex broker (stacks/docker0*/wgkex on main), not on the pgw #}
wgkex-service-broker:
  service.dead:
    - name: wgkex-broker
    - enable: False

/etc/systemd/system/wgkex-broker.service:
  file.absent:
    - require:
      - service: wgkex-service-broker

/etc/systemd/system/wgkex-worker.service:
  file.managed:
    - source: salt://parker/wgkex/wgkex-worker.service


/etc/wgkex.yaml:
  file.managed:
    - source: salt://parker/wgkex/wgkex.yaml.jinja
    - template: jinja

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
