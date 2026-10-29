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

{%- set pjsip_reg = "pbx01.voip.philunet.de-reg" %}
{%- set pjsip_reg_opts = {
  "max_retries": "10000",
  "retry_interval": "60",
  "forbidden_retry_interval": "300",
  "fatal_retry_interval": "300",
  "auth_rejection_permanent": "no",
} %}
{#- pjsip.conf is not managed here and has duplicate section names, so ini.options_present would collapse them; edit only these options in the registration section. #}
{%- for opt, val in pjsip_reg_opts.items() %}

asterisk_pjsip_reg_{{ opt }}_add:
  file.replace:
    - name: /etc/asterisk/pjsip.conf
    - pattern: '^(\[{{ pjsip_reg | regex_escape }}\][ \t]*\n)(?!(?:(?!^\[)[^\n]*\n)*?^[ \t]*{{ opt }}[ \t]*=)'
    - repl: '\g<1>{{ opt }} = {{ val }}\n'
    - ignore_if_missing: True
    - require:
      - pkg: asterisk

asterisk_pjsip_reg_{{ opt }}:
  file.replace:
    - name: /etc/asterisk/pjsip.conf
    - pattern: '^(\[{{ pjsip_reg | regex_escape }}\][ \t]*\n(?:(?!^\[)[^\n]*\n)*?[ \t]*{{ opt }}[ \t]*=[ \t]*)[^\n]*$'
    - repl: '\g<1>{{ val }}'
    - ignore_if_missing: True
    - require:
      - file: asterisk_pjsip_reg_{{ opt }}_add
{%- endfor %}

asterisk_pjsip_reg_reload:
  cmd.run:
    - name: asterisk -rx 'module reload res_pjsip_outbound_registration.so'
    - onchanges:
{%- for opt in pjsip_reg_opts %}
      - file: asterisk_pjsip_reg_{{ opt }}_add
      - file: asterisk_pjsip_reg_{{ opt }}
{%- endfor %}
{% endif %}
