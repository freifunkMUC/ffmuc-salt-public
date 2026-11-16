{#- Host-generated key pair, only for pki.mode keygen or local; the public key goes to the master via mine (nebula_host_pub). #}
{%- from "nebula/map.jinja" import nebula with context %}
{%- set mode = nebula.pki.get('mode', 'legacy') %}
{%- if nebula.enabled and mode not in ['legacy', 'keygen', 'local'] %}
{{ salt['test.exception']("nebula: invalid pki.mode '" ~ mode ~ "' (legacy, keygen or local)") }}
{%- endif %}
{%- if nebula.enabled and mode in ['keygen', 'local'] %}
{%- set dir = '/etc/nebula' %}
{%- set in_mine = salt['mine.get'](grains['id'], 'nebula_host_pub') or {} %}

include:
  - nebula.install

nebula-key-dir:
  file.directory:
    - name: {{ dir }}
    - makedirs: True

{#- nebula-cert cannot derive host.pub from host.key; never regenerate over an existing key #}
nebula-host-pub-missing:
  cmd.run:
    - name: echo "{{ dir }}/host.key exists but host.pub is missing; restore host.pub from backup or move host.key away by hand and rerun (the cert is bound to the key)" >&2; exit 1
    - onlyif: test -s {{ dir }}/host.key && test ! -s {{ dir }}/host.pub
    - require:
        - file: nebula-key-dir

nebula-host-keygen:
  cmd.run:
    - name: /usr/bin/nebula-cert keygen -curve 25519 -out-key {{ dir }}/host.key -out-pub {{ dir }}/host.pub
    - creates: {{ dir }}/host.key
    - require:
        - file: nebula-key-dir
        - cmd: nebula-host-pub-missing
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
        - cmd: nebula-host-keygen

{#- no file.managed here: it would create an empty host.pub #}
nebula-host-pub-mode:
  cmd.run:
    - name: chmod 0644 {{ dir }}/host.pub
    - onlyif: test -s {{ dir }}/host.pub && test "$(stat -c %a {{ dir }}/host.pub)" != 644
    - require:
        - cmd: nebula-host-keygen

nebula-host-pub-mine:
  module.run:
    - mine.update: []
    - require:
        - cmd: nebula-host-pub-mode
{%- if in_mine %}
    - onchanges:
        - cmd: nebula-host-keygen
{%- endif %}
{%- endif %}
