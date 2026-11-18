{#- nftables counters for node traffic between the pgws of a site, read by telegraf
    (telegraf/files/parker_gateway_stats.py). Its own table: nftables.service stays off,
    because its default /etc/nftables.conf flushes the iptables-nft rules. #}
{%- set role = salt['pillar.get']('netbox:role:name') %}
{%- if 'parker-gateway' in role %}

/etc/nftables-parker-xpgw-counters.nft:
  file.managed:
    - source: salt://parker/xpgw-counters/files/parker-xpgw-counters.nft.jinja
    - template: jinja
    - mode: "0644"
    - check_cmd: /usr/sbin/nft -c -f

/etc/systemd/system/parker-xpgw-counters.service:
  file.managed:
    - source: salt://parker/xpgw-counters/files/parker-xpgw-counters.service

parker-xpgw-counters:
  service.running:
    - enable: True
    - reload: False
    - require:
      - file: /etc/nftables-parker-xpgw-counters.nft
    - watch:
      - file: /etc/nftables-parker-xpgw-counters.nft
      - file: /etc/systemd/system/parker-xpgw-counters.service

{% endif %}
