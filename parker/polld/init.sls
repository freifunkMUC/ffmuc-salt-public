{% set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'parker-gateway' in role %}

{% set user = "polld" %}

# Create Groups
group-{{ user }}:
  group.present:
      - name: {{ user }}

# Create User
user-{{ user }}:
  user.present:
    - name: {{ user }}
    - shell: /bin/sh
    - home: /srv/polld
    - createhome: True
    - groups:
      - {{ user }}
    - system: False
    - require:
      - group: group-{{ user }}

polld-python3-virtualenv:
  pkg.installed:
    - name: python3-virtualenv

/srv/polld:
  file.directory:
    - mode: "0755"
    - user: polld
    - group: polld
    - require:
      - user: user-{{ user }}

/srv/polld/polld-git:
  git.latest:
    - name: https://github.com/freifunkMUC/polld.git
    - rev: main
    - target: /srv/polld/polld-git
    - user: polld
    - force_reset: True
    - force_fetch: True
    - require:
      - file: /srv/polld

/srv/polld/polld-git/venv:
  virtualenv.managed:
    - name: /srv/polld/polld-git/venv
    - requirements: /srv/polld/polld-git/requirements.txt
    - user: polld
    - runas: polld  {# workaround for https://github.com/saltstack/salt/issues/59088 #}
    - require:
      - git: /srv/polld/polld-git

/etc/systemd/system/polld.service:
  file.managed:
    - source: salt://parker/polld/polld.service

/etc/polld.yaml:
  file.managed:
    - source: salt://parker/polld/polld.yaml.jinja
    - template: jinja
    - context:
        netbox_token: {{ salt['pillar.get']('netbox:config_context:parker:polld:netbox_token') }}

polld-service:
  service.running:
    - name: polld
    - enable: True
    - require:
        - file: /etc/polld.yaml
        - git: /srv/polld/polld-git
    - watch:
        - file: /etc/polld.yaml
        - git: /srv/polld/polld-git

{% endif %}
