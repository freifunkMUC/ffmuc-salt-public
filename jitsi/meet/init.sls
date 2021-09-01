###
# Jitsi Meet Web Package
###
{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.meet.enabled %}

jitsi-meet-web-pkgs:
  pkg.installed:
    - sources:
      - jitsi-meet-web: salt://jitsi/meet/jitsi-meet-web_{{ jitsi.meet.version }}_all.deb
      - jitsi-meet-web-config: salt://jitsi/meet/jitsi-meet-web-config_{{ jitsi.meet.version }}_all.deb
    - hold: True

{% for domain in ["meet.ffmuc.net","klassenkonferenz.de"] %}
/etc/jitsi/meet/{{ domain }}-config.js:
  file.managed:
    - source:
      - salt://jitsi/meet/{{ domain }}-config.js.jinja
      - salt://jitsi/meet/domain-config.js.jinja
    - template: jinja
    - defaults:
      domain: {{ domain }}
{% endfor %}

/usr/share/jitsi-meet/interface_config.js:
  file.managed:
    - source:
      - salt://jitsi/meet/interface_config.js

/etc/jitsi/meet/numbers.json:
  file.managed:
    - source: salt://jitsi/meet/numbers.json
