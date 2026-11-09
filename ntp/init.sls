#
# NTP
#
{#- Debian 13 has no ntp package: ntpsec, with its own config path #}
{%- set ntpsec = grains.os == 'Debian' and grains.osmajorrelease >= 13 %}

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
