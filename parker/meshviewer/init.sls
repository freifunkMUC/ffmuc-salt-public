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

{#- Each pgw merges the yanic data of all sites into one meshviewer.json:
    its own file, and the files of the other sites from the public map. #}
{%- set map_sites = ['muc01', 'vie01'] %}
{%- set site = salt['pillar.get']('netbox:site:slug') %}
{%- set remote_urls = [] %}
{%- for s in map_sites if s != site %}
{%-   do remote_urls.append('https://map-parker.ffmuc.net/data/' ~ s ~ '/meshviewer.json') %}
{%- endfor %}
/usr/local/bin/merge-map-data.py:
  file.managed:
    - source: salt://parker/meshviewer/merge-map-data.py
    - mode: "0755"

/srv/yanic/merged:
  file.directory:
    - user: yanic
    - group: yanic
    - mode: "0755"
    - require:
      - file: /srv/yanic

/etc/systemd/system/merge-map-data.service:
  file.managed:
    - contents: |
        [Unit]
        Description=Merge the Parker map data of all sites
        [Service]
        Type=oneshot
        User=yanic
        ExecStart=/usr/local/bin/merge-map-data.py /srv/yanic/meshviewer.json /srv/yanic/merged/meshviewer.json {{ remote_urls | join(' ') }}

/etc/systemd/system/merge-map-data.timer:
  file.managed:
    - contents: |
        [Unit]
        Description=Merge the Parker map data of all sites
        [Timer]
        OnBootSec=1min
        OnUnitActiveSec=30s
        [Install]
        WantedBy=timers.target

merge-map-data.timer:
  service.running:
    - enable: True
    - require:
      - file: /usr/local/bin/merge-map-data.py
      - file: /srv/yanic/merged
    - watch:
      - file: /etc/systemd/system/merge-map-data.service
      - file: /etc/systemd/system/merge-map-data.timer

{% endif %}
