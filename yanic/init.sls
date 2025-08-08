#
# yanic
#

{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
{% if "yanic" in tags %}

# add yanic directory
/srv/yanic:
  file.directory:
    - makedirs: True

# copy yanic binary to destination
# the binary needs to be provided by the salt-master
yanic:
  pkg.installed:
    - sources:
      - yanic: https://apt.ffmuc.net/yanic_1.8.3-2_amd64.deb
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
    - source: salt://yanic/yanic.conf.tmpl
    - template: jinja
    - require:
      - file: /srv/yanic

{% endif %}{# yanic in tags #}
