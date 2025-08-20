#
# yanic
#

{%- set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'nextgen-gateway' in role or 'parker-gateway' in role %}

{%- set user = "yanic" %}

# Create Group
group-{{ user }}:
  group.present:
      - name: {{ user }}

# Create User
user-{{ user }}:
  user.present:
    - name: {{ user }}
    - shell: /bin/sh
    - home: /srv/yanic
    - createhome: True
    - groups:
      - {{ user }}
    - system: False
    - require:
      - group: group-{{ user }}

/srv/yanic:
  file.directory:
    - mode: "0755"
    - user: yanic
    - group: yanic
    - require:
      - user: user-{{ user }}

# copy yanic binary to destination
# the binary needs to be provided by the salt-master
yanic:
  pkg.installed:
    - sources:
      - yanic: https://apt.ffmuc.net/yanic_1.5.2-2_amd64.deb
  service.running:
    - enable: True
    - require:
      - file: /etc/yanic.conf
      - file: /etc/systemd/system/yanic.service
    - watch:
      - file: /etc/yanic.conf
      - pkg: yanic

# copy systemd yanic.service
/etc/systemd/system/yanic.service:
  file.managed:
    - source: salt://yanic/yanic.service
    - require:
      - pkg: yanic

# add configuration file
/etc/yanic.conf:
  file.managed:
    - source: salt://parker/yanic/yanic.conf.tmpl
    - template: jinja
    - require:
      - file: /srv/yanic

{% endif %}{# yanic in tags #}
