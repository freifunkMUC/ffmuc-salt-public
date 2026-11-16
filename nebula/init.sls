###
# nebula
###

{%- from "nebula/map.jinja" import nebula with context %}
{% if nebula.enabled %}
{%- set local_pki = nebula.pki.get('mode', 'legacy') == 'local' %}
{%- set cert_name = 'host' if local_pki else grains['id'] %}
{%- set ca_files = [] %}
{%- for ca in nebula.pki.cas %}
{%- do ca_files.append("nebula/cert/" ~ ca) %}
{%- endfor %}
{%- set crt_files = [] %}
{%- for v in nebula.pki.cert_versions %}
{%- do crt_files.append("nebula/cert/" ~ ("new/" if local_pki else "") ~ ("" if v == 1 else "v" ~ v ~ "/") ~ grains["id"] ~ ".crt") %}
{%- endfor %}

include:
  - nebula.install
  - nebula.key

/etc/nebula/ca.crt:
  file.managed:
    - source: salt://nebula/files/bundle.pem.jinja
    - template: jinja
    - context:
        files: {{ ca_files | tojson }}
    - require:
        - file: /etc/nebula/config.yml
        - file: /etc/nebula/{{ cert_name }}.crt

/etc/nebula/{{ cert_name }}.crt:
  file.managed:
    - source: salt://nebula/files/bundle.pem.jinja
    - template: jinja
    - context:
        files: {{ crt_files | tojson }}
    - makedirs: True
    - user: root
    - group: root
    - mode: "0644"

{% if not local_pki %}
/etc/nebula/{{ grains['id'] }}.key:
  file.managed:
    - source: salt://nebula/cert/{{ grains['id'] }}.key
    - makedirs: True
    - user: root
    - group: root
    - mode: "0640"
    - show_changes: False  # never print the private key
{% endif %}

{% if nebula.loophole.enabled %}
generate_ssh_host_ed25519_key:
  cmd.run:
    - name: ssh-keygen -t ed25519 -q -N "" -f /etc/nebula/ssh_host_ed25519_key
    - unless: test -f /etc/nebula/ssh_host_ed25519_key
    - require_in:
      - file: /etc/nebula/config.yml
{% endif %}

/etc/nebula/config.yml:
  file.managed:
    - source:
        - salt://nebula/files/{{ grains['id'] }}-config.yml.jinja
        - salt://nebula/files/config.yml.jinja
    - makedirs: True
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - require:
        - file: /etc/nebula/{{ cert_name }}.crt
        - file: /etc/nebula/{{ cert_name }}.key

# restarting (not reloading) keeps a package upgrade from running the new binary
# only after a second restart racing the first one
nebula-config-test:
  cmd.run:
    - name: /usr/bin/nebula -test -config /etc/nebula/config.yml
    - onchanges:
        - file: /etc/nebula/config.yml
        - file: /etc/nebula/ca.crt
        - file: /etc/nebula/{{ cert_name }}.crt
        - file: /etc/nebula/{{ cert_name }}.key
        - pkg: nebula-pkg

nebula-service:
  service.running:
    - enable: True
    - name: nebula
    - require:
        - file: /etc/nebula/config.yml
        - file: /etc/nebula/ca.crt
        - file: /etc/nebula/{{ cert_name }}.crt
        - file: /etc/nebula/{{ cert_name }}.key
        - pkg: nebula-pkg
        - cmd: nebula-config-test
    - watch:
        - file: /etc/nebula/config.yml
        - file: /etc/nebula/ca.crt
        - file: /etc/nebula/{{ cert_name }}.crt
        - file: /etc/nebula/{{ cert_name }}.key
        - pkg: nebula-pkg

{% else %}
{# remove old config to allow migration to new file destination #}
/etc/nebula/ca.crt:
  file.absent
/etc/nebula/{{ grains['id'] }}.crt:
  file.absent
/etc/nebula/{{ grains['id'] }}.key:
  file.absent
/etc/nebula/config.yml:
  file.absent
/etc/systemd/system/nebula.service:
  file.absent

{% endif %}