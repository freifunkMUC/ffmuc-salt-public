{# NOTE: use config.get, not pillar.get, for netbox reads. Salt wraps netbox sub-dicts
   containing a sensitive key as a MaskedDict whose redacted repr ('**********') leaks
   through, masking sibling values (e.g. tag_list entries). config.get returns a plain copy. #}
{% set tags = salt['config.get']('netbox:tag_list', []) %}
{% if "haproxy" in tags %}

haproxy-ppa:
  # using ppa for setup uses more time then just copying that file...
  #pkgrepo.managed:
    #- ppa: vbernat/haproxy-3.2
    #- file: /etc/apt/sources.list.d/haproxy-3.2.list
  file.managed:
    - name: /etc/apt/sources.list.d/vbernat-ubuntu-haproxy-3_2-noble.sources
    - source: salt://haproxy/ppa-haproxy.sources
    - template: jinja
    - require_in:
      - pkg: haproxy

update-repo:
  cmd.run:
    - name: apt update
    - onchanges:
      - file: haproxy-ppa

haproxy:
  pkg.installed:
    - name: haproxy-awslc
    - version: 3.4.2-0+ha34+ubuntu24.04u1

haproxy-keyring-dir:
  file.directory:
    - name: /usr/share/keyrings
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True

haproxy-gpg-key:
  cmd.run:
    - name: wget -qO /usr/share/keyrings/HAPROXY-key-community.asc https://www.haproxy.com/download/haproxy/HAPROXY-key-community.asc
    - creates: /usr/share/keyrings/HAPROXY-key-community.asc
    - require:
      - file: haproxy-keyring-dir
    - require_in:
      - pkg: haproxy

haproxy-service:
  service.running:
    - name: haproxy
    - enable: True
    - reload: True
    - require:
      - pkg: haproxy
    - watch:
      - cmd: haproxy-configtest

haproxy-configtest:
  cmd.run:
    - name: /usr/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
    - onchanges:
      - file: /etc/haproxy/haproxy.cfg
      - file: /etc/haproxy/maps/abuse_ips.map
      - file: /etc/haproxy/maps/abuse_rooms.map
      - file: /etc/haproxy/errors/403.http
      - file: /etc/haproxy/responses/ip_response.json
      - file: /etc/haproxy/responses/ip_lookup_response.json
      - file: /etc/haproxy/responses/ip_response.html
      - file: /etc/haproxy/responses/ip_response.txt
{% if "packetyeeter-collector" in tags %}
      - file: /etc/haproxy/lua/ja4.lua
      - file: /etc/haproxy/lua/ja4h.lua
      - file: packetyeeter-spoe-conf
      - file: packetyeeter-spoe-tune-timeout-hello
      - file: packetyeeter-spoe-tune-timeout-processing
{% endif %}

{% if "packetyeeter-collector" in tags %}
{# JA4/JA4H fingerprinting (Lua) + the SPOE config that exports signals to the
   local packetyeeter collector (127.0.0.1:9876). Fetched directly from the
   upstream repo (same pattern as other third-party assets in this repo, e.g.
   GeoLite mmdb) rather than vendoring a copy, to avoid transcription risk in
   security-sensitive fingerprinting code and stay in sync with upstream. #}
/etc/haproxy/lua:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - pkg: haproxy

/etc/haproxy/lua/ja4.lua:
  file.managed:
    - source: https://raw.githubusercontent.com/awlx/packetyeeter/main/examples/ja4.lua
    - skip_verify: True
    - mode: "0644"
    - require:
      - file: /etc/haproxy/lua

/etc/haproxy/lua/ja4h.lua:
  file.managed:
    - source: https://raw.githubusercontent.com/awlx/packetyeeter/main/examples/ja4h.lua
    - skip_verify: True
    - mode: "0644"
    - require:
      - file: /etc/haproxy/lua

/etc/haproxy/spoe:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - pkg: haproxy

packetyeeter-spoe-conf:
  file.managed:
    - name: /etc/haproxy/spoe/packetyeeter.conf
    - source: https://raw.githubusercontent.com/awlx/packetyeeter/main/examples/packetyeeter.spoe.conf
    - skip_verify: True
    - mode: "0644"
    - require:
      - file: /etc/haproxy/spoe

{# Tighten the upstream example's default timeouts, which are far more
   generous than real measured processing time (observed avg ~14us/message
   in production - see packetyeeter_spoe_processing_seconds metric). This
   filter runs synchronously on every HTTP response (event on-http-response),
   so "timeout processing" directly bounds worst-case added latency per
   request when the local collector is slow/stuck; "on-timeout ignore" +
   "option continue-on-error" mean a timeout just skips this request's
   signal rather than failing it, so tightening is safe. Patched via
   file.replace (not a local template) to stay in sync with upstream's
   message/args definitions, which we intentionally fetch rather than
   vendor (see comment above). #}
packetyeeter-spoe-tune-timeout-hello:
  file.replace:
    - name: /etc/haproxy/spoe/packetyeeter.conf
    - pattern: '^(\s*timeout hello\s+).*$'
    - repl: '\g<1>100ms'
    - flags:
      - MULTILINE
    - require:
      - file: packetyeeter-spoe-conf

packetyeeter-spoe-tune-timeout-processing:
  file.replace:
    - name: /etc/haproxy/spoe/packetyeeter.conf
    - pattern: '^(\s*timeout processing\s+).*$'
    - repl: '\g<1>50ms'
    - flags:
      - MULTILINE
    - require:
      - file: packetyeeter-spoe-conf
{% endif %}

/etc/haproxy/haproxy.cfg:
  file.managed:
    - source: salt://haproxy/haproxy.cfg
    - template: jinja
    - require:
      - pkg: haproxy

/etc/haproxy/responses:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - pkg: haproxy

/etc/haproxy/maps:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - pkg: haproxy

/etc/haproxy/responses/ip_response.json:
  file.managed:
    - source: salt://haproxy/files/ip_response.json
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/responses

/etc/haproxy/responses/ip_lookup_response.json:
  file.managed:
    - source: salt://haproxy/files/ip_lookup_response.json
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/responses

/etc/haproxy/responses/ip_response.html:
  file.managed:
    - source: salt://haproxy/files/ip_response.html
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/responses

/etc/haproxy/responses/ip_response.txt:
  file.managed:
    - source: salt://haproxy/files/ip_response.txt
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/responses

/etc/haproxy/maps/abuse_ips.map:
  file.managed:
    - source: salt://haproxy/files/abuse_ips.map
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/maps

/etc/haproxy/maps/abuse_rooms.map:
  file.managed:
    - source: salt://haproxy/files/abuse_rooms.map
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /etc/haproxy/maps

/etc/haproxy/errors/403.http:
  file.managed:
    - source: salt://haproxy/files/403.http
    - user: root
    - group: root
    - mode: "0644"
    - makedirs: True
    - require:
      - pkg: haproxy

/etc/logrotate.d/haproxy:
  file.managed:
    - source: salt://haproxy/logrotate-haproxy
    - user: root
    - group: root
    - mode: "0644"

/etc/cron.d/haproxy-logrotate:
  file.managed:
    - source: salt://haproxy/haproxy-logrotate.cron
    - user: root
    - group: root
    - mode: "0644"

# GeoIP support for ip.ffmuc.net
haproxy-geoip-deps:
  pkg.installed:
    - pkgs:
      - python3-maxminddb

/etc/haproxy/geoip:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - pkg: haproxy

/etc/haproxy/geoip/generate_geoip_maps.py:
  file.managed:
    - source: salt://haproxy/files/generate_geoip_maps.py
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - file: /etc/haproxy/geoip

/etc/haproxy/geoip/GeoLite2-City.mmdb:
  cmd.run:
    - name: wget -qO /etc/haproxy/geoip/GeoLite2-City.mmdb https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb
    - creates: /etc/haproxy/geoip/GeoLite2-City.mmdb
    - require:
      - file: /etc/haproxy/geoip

/etc/haproxy/geoip/GeoLite2-ASN.mmdb:
  cmd.run:
    - name: wget -qO /etc/haproxy/geoip/GeoLite2-ASN.mmdb https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb
    - creates: /etc/haproxy/geoip/GeoLite2-ASN.mmdb
    - require:
      - file: /etc/haproxy/geoip

# Generate HAProxy map files from mmdb databases
haproxy-generate-geoip-maps:
  cmd.run:
    - name: python3 /etc/haproxy/geoip/generate_geoip_maps.py
    - creates: /etc/haproxy/maps/geoip_country.map
    - require:
      - pkg: haproxy-geoip-deps
      - file: /etc/haproxy/geoip/generate_geoip_maps.py
      - cmd: /etc/haproxy/geoip/GeoLite2-City.mmdb
      - cmd: /etc/haproxy/geoip/GeoLite2-ASN.mmdb
      - file: /etc/haproxy/maps
    - require_in:
      - cmd: haproxy-configtest

# Update GeoIP databases and regenerate maps weekly
/etc/cron.d/haproxy-geoip-update:
  file.managed:
    - contents: |
        # Update GeoLite2 databases weekly (Sunday 3am) and regenerate maps
        0 3 * * 0 root wget -qO /etc/haproxy/geoip/GeoLite2-City.mmdb https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb && wget -qO /etc/haproxy/geoip/GeoLite2-ASN.mmdb https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb && python3 /etc/haproxy/geoip/generate_geoip_maps.py && systemctl reload haproxy
    - user: root
    - group: root
    - mode: "0644"

{% endif %}
