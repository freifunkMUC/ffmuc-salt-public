{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
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
    - version: 3.3.0-0+ha33+ubuntu24.04u2

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

/etc/haproxy/haproxy.cfg:
  file.managed:
    - source: salt://haproxy/haproxy.cfg
    - template: jinja
    - require:
      - pkg: haproxy
    - watch_in:
      - cmd: haproxy-configtest

/etc/haproxy/abuse_ips.map:
  file.managed:
    - source: salt://haproxy/files/abuse_ips.map
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - pkg: haproxy
    - watch_in:
      - cmd: haproxy-configtest

/etc/haproxy/abuse_rooms.map:
  file.managed:
    - source: salt://haproxy/files/abuse_rooms.map
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - pkg: haproxy
    - watch_in:
      - cmd: haproxy-configtest

/etc/haproxy/errors/403.http:
  file.managed:
    - source: salt://haproxy/files/403.http
    - user: root
    - group: root
    - mode: "0644"
    - makedirs: True
    - require:
      - pkg: haproxy
    - watch_in:
      - cmd: haproxy-configtest

{% endif %}
