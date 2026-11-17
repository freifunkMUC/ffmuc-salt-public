{% set role = salt['pillar.get']('netbox:role:name') %}

{%- if 'parker-gateway' in role %}

{% set domain = grains['id'] | regex_replace('in\.ffmuc\.net','ext.ffmuc.net') %}
meshviewer-directory:
  file.directory:
    - name: /srv/www/{{ domain }}/meshviewer
    - makedirs: True
    - user: www-data
    - group: www-data
    - mode: "0750"

meshviewer-code:
  archive.extracted:
    - name: /srv/www/{{ domain }}/meshviewer
    - source: https://github.com/freifunk/meshviewer/releases/download/v12.6.0/meshviewer-build.zip
    - source_hash: sha256=6e8720e33e3c497b0bc16aa36345931cbbc3b2865b92d543ecced1c0811fab95
    - use_etag: True
    - user: www-data
    - group: www-data
    - clean: True
    - enforce_toplevel: False
    - require:
      - file: meshviewer-directory

meshviewer-config:
  file.managed:
    - name: /srv/www/{{ domain }}/meshviewer/config.json
    - source: salt://parker/meshviewer/config.json
    - user: www-data
    - group: www-data
    - mode: "0640"

{% endif %}
