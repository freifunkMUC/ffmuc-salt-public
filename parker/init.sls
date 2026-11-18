# - 464XLAT
#   - https://nicmx.github.io/Jool/en/run-nat64.html
#   - https://nicmx.github.io/Jool/en/config-atomic.html
#   - https://nicmx.github.io/Jool/en/usr-flags-pool4.html#empty-pool4
#     - sysctl net.ipv4.ip_local_port_range

# Interface setup plan:
# wg-nodes: node peers
# vlan100x (mgmt): iBGP and BFD to the other pgws of the site, on a fixed link-local (parker/bird2)
#
{%- set role = salt['pillar.get']('netbox:role:name') %}

{%- if "parker-gateway" in role %}
include:
  - .systemd-networkd
  - iptables
  - .bird2
  - pdns-recursor
  - .plat
  - .wgkex
  - .nginx
  - .yanic
  - .respondd
  - .xpgw-counters
  - .polld
  - .meshviewer
{% endif %}
