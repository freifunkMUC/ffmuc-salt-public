#
# NTP
#
{#- Debian 13 and Ubuntu 26.04 have no ntp package: ntpsec, with its own config path #}
{%- set ntpsec = (grains.os == 'Debian' and grains.osmajorrelease >= 13) or (grains.os == 'Ubuntu' and grains.osmajorrelease >= 26) %}

ntp:
  pkg.installed:
    - name: {{ 'ntpsec' if ntpsec else 'ntp' }}

{%- if ntpsec %}
/etc/ntpsec/ntp.conf:
  file.managed:
    - source: salt://ntp/ntpsec.conf
    - require:
      - pkg: ntp

ntpsec:
  service.running:
    - enable: True
    - watch:
      - file: /etc/ntpsec/ntp.conf
{%- else %}

/etc/ntp.conf:
  file.managed:
    - source: salt://ntp/ntp.conf
{%- endif %}
