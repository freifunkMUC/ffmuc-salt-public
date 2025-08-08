{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.asterisk.enabled %}

asterisk:
  pkg.installed:
    - name: asterisk
  service.running:
    - enable: True
    - reload: True
    - require:
      - file: /etc/asterisk/sip.conf
      - file: /etc/asterisk/extensions.conf
    - watch:
      - file: /etc/asterisk/sip.conf
      - file: /etc/asterisk/extensions.conf

/etc/asterisk/sip.conf:
  file.managed:
    - source: salt://jitsi/asterisk/sip.conf.jinja
    - template: jinja

/etc/asterisk/extensions.conf:
  file.managed:
    - source: salt://jitsi/asterisk/extensions.conf.jinja
    - template: jinja

/var/lib/asterisk/sounds/de:
  file.directory

asterisk_german_sounds_core:
  archive.extracted:
{% if grains.oscodename == "debian" %}
    - name: /var/lib/asterisk/sounds/de
{% else %}{# ubuntu #}
    - name: /usr/share/asterisk/sounds/de
{% endif %}
    - source: https://apt.ffmuc.net/asterisk-sounds-core-de-2.11.19.zip
    - enforce_toplevel: False
    - skip_verify: True
    - user: asterisk
    - group: asterisk

asterisk_german_sounds_extra:
  archive.extracted:
{% if grains.oscodename == "debian" %}
    - name: /var/lib/asterisk/sounds/de
{% else %}{# ubuntu #}
    - name: /usr/share/asterisk/sounds/de
{% endif %}
    - source: https://apt.ffmuc.net/asterisk-sounds-extra-de-2.11.19.zip
    - enforce_toplevel: False
    - skip_verify: True
    - user: asterisk
    - group: asterisk
{% endif %}
