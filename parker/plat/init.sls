{#- NAT64 per pgw. Each pgw needs its own pool4: the NAT64 state is on one pgw only.
    Default: private pool4, the uplink SNAT (iptables) gives the public address. #}
{%- set nat64_pool4 = salt['pillar.get']('netbox:config_context:network:nat64_ipv4', '10.80.64.1/32') %}
{%- if '/' not in nat64_pool4 %}{% set nat64_pool4 = nat64_pool4 ~ '/32' %}{% endif %}
{%- set nat64_ipv6 = salt['pillar.get']('netbox:config_context:network:nat64_ipv6', 'fd00::64:64') %}
{#- The broker gives the nodes a tunnel MTU of 1375 (wgkex). The node CLAT drops
    IPv6 fragments, so Jool must fragment only above the tunnel MTU (default 1280). #}
{%- set lowest_ipv6_mtu = salt['pillar.get']('netbox:config_context:parker:tunnel_mtu', 1375) %}
jool-packages:
  pkg.installed:
    - names:
      - jool-dkms
      - jool-tools

jool-config:
  file.managed:
    - source: salt://parker/plat/jool.conf.j2
    - name: /etc/jool/jool.conf
    - mode: "0644"
    - makedirs: True
    - template: jinja
    - context:
        nat64_pool4: {{ nat64_pool4 }}
        lowest_ipv6_mtu: {{ lowest_ipv6_mtu }}
    - require:
      - pkg: jool-packages

jool-script:
  file.managed:
    - source: salt://parker/plat/setup-jool.sh.j2
    - name: /usr/local/sbin/setup-jool.sh
    - mode: "0755"
    - template: jinja
    - context:
        nat64_ipv6: {{ nat64_ipv6 }}
        nat64_pool4: {{ nat64_pool4 }}
        nat64_pool4_address: {{ nat64_pool4.split('/')[0] }}

jool-unit:
  file.managed:
    - source: salt://parker/plat/jool.service
    - name: /etc/systemd/system/jool.service
    - mode: "0644"

jool-service:
  service.running:
    - name: jool
    - enable: True
    - reload: True
    - watch:
      - file: jool-config
      - file: jool-script
      - file: jool-unit
    - require:
      - pkg: jool-packages
      - file: jool-config
      - file: jool-script
      - file: jool-unit
