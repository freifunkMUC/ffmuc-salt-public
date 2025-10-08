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
    - require_in:
      - pkg: haproxy

update-repo:
  cmd.run:
    - name: apt update
    - onchanges:
      - file: haproxy-ppa

haproxy:
  pkg.installed:
    - version: 3.2.6-1ppa1~noble

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

{% endif %}