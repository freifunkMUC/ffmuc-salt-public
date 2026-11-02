##
# Sets the XMPP service account passwords from the pillar (rotation). Not part of the highstate:
#   salt 'jicofo0*' state.apply jitsi.prosody.passwd [pillar='{"prosody_passwd_force": true}']
# Changing a password disconnects the account's sessions, the clients need their new config right after.
##
{%- from "jitsi/map.jinja" import jitsi with context %}

{%- if jitsi.prosody.enabled %}
{%- set force = '--force ' if salt['pillar.get']('prosody_passwd_force', False) else '' %}
{#- the main Prosody's auth and recorder domains follow auth_backend, the visitor nodes are always internal_hashed #}
{%- set backend = '--backend ' ~ jitsi.prosody.auth_backend ~ ' ' %}

{%- macro setpw(id, user, domain, password, data='/var/lib/prosody', config='', opts=backend) %}
{%- set enc = {'.': '%2e', '-': '%2d', '_': '%5f'} %}
{%- set ns = namespace(d=domain, u=user) %}
{%- for c, e in enc.items() %}
{%-   set ns.d = ns.d.replace(c, e) %}
{%-   set ns.u = ns.u.replace(c, e) %}
{%- endfor %}
prosody-passwd-{{ id }}:
  cmd.run:
    - name: "/usr/local/sbin/prosody-setpw {{ force }}{{ opts }}{{ config }}{{ user }}@{{ domain }} {{ data }}/{{ ns.d }}/accounts/{{ ns.u }}.dat"
    - stdin: {{ (password ~ "\n") | tojson }}
    - output_loglevel: quiet
    - stateful: True
    - require:
      - file: /usr/local/sbin/prosody-setpw
{%- endmacro %}

/usr/local/sbin/prosody-setpw:
  file.managed:
    - source: salt://jitsi/prosody/files/prosody-setpw.sh
    - mode: "0750"

{{ setpw('jicofo', jitsi.jicofo.username, jitsi.xmpp.auth_domain, jitsi.jicofo.password) }}
{{ setpw('jvb', jitsi.videobridge.username, jitsi.xmpp.auth_domain, jitsi.videobridge.password) }}
{%- if jitsi.jibri_enabled %}
{{ setpw('jibri-control', jitsi.jibri.xmpp.control_login.username, jitsi.jibri.xmpp.control_login.domain, jitsi.jibri.xmpp.control_login.password) }}
{{ setpw('jibri-recorder', jitsi.jibri.xmpp.call_login.username, jitsi.jibri.xmpp.call_login.domain, jitsi.jibri.xmpp.call_login.password) }}
{%- endif %}
{%- if jitsi.transcription.enabled %}
{{ setpw('transcriber', jitsi.transcription.transcriber_username, "recorder." ~ jitsi.public_domain, jitsi.transcription.transcriber_password) }}
{{ setpw('jigasi', jitsi.transcription.jigasi_username, jitsi.xmpp.auth_domain, jitsi.transcription.jigasi_password) }}
{%- endif %}
{%- if jitsi.visitors.enabled %}
{%-   for i in range(1, jitsi.visitors.vnodes | int + 1) %}
{{ setpw('jicofo-v' ~ i, jitsi.jicofo.username, "auth." ~ jitsi.visitors.domain, jitsi.jicofo.password, '/var/lib/prosody-v' ~ i, '--config /etc/prosody-v' ~ i ~ '/prosody.cfg.lua ', '') }}
{%-   endfor %}
{%- endif %}
{%- endif %}
