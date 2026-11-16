{#- Host-generated key pair, only for pki.mode keygen or local; the public key goes to the master via mine (nebula_meet_host_pub). #}
{%- from "nebula-meet/map.jinja" import nebula with context %}
{%- if nebula.enabled and nebula.pki.get('mode', 'legacy') in ['keygen', 'local'] %}
{%- set dir = '/etc/nebula-meet' %}

nebula-meet-key-dir:
  file.directory:
    - name: {{ dir }}
    - makedirs: True

nebula-meet-host-keygen:
  cmd.run:
    - name: /usr/bin/nebula-cert keygen -curve 25519 -out-key {{ dir }}/host.key -out-pub {{ dir }}/host.pub
    - creates:
        - {{ dir }}/host.key
        - {{ dir }}/host.pub
    - require:
        - file: nebula-meet-key-dir
        - pkg: nebula-pkg

{#- content is never managed, only the mode #}
{{ dir }}/host.key:
  file.managed:
    - replace: False
    - show_changes: False
    - user: root
    - group: root
    - mode: "0600"
    - require:
        - cmd: nebula-meet-host-keygen

{{ dir }}/host.pub:
  file.managed:
    - replace: False
    - user: root
    - group: root
    - mode: "0644"
    - require:
        - cmd: nebula-meet-host-keygen

nebula-meet-host-pub-mine:
  module.run:
    - mine.update: []
    - onchanges:
        - cmd: nebula-meet-host-keygen
{%- endif %}
