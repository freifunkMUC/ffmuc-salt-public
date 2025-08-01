# - 464XLAT
#   - https://nicmx.github.io/Jool/en/run-nat64.html
#   - https://nicmx.github.io/Jool/en/config-atomic.html
#   - https://nicmx.github.io/Jool/en/usr-flags-pool4.html#empty-pool4
#     - sysctl net.ipv4.ip_local_port_range

# Interface setup plan:
# wg-nodes: node peers
# wg-<bb-gw0X>: crosslink/backbone between gateways, with default routes as AllowedIPs with OSPF running on top
#
{%- set role = salt['pillar.get']('netbox:role:name') %}

{%- if "parker-gateway" in role %}
include:
  - .systemd-networkd
  - iptables
  - .bird2
  - .plat
  - .wgkex
  - .nginx
{% endif %}
