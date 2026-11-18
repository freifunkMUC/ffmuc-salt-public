#
# Larger socket buffers and backlog for hosts with high UDP/packet load
# (dnsdist hosts and Parker gateways). With kernel defaults (208 KB) UDP bursts
# overflow the receive buffers (RcvbufErrors). New defaults apply only to sockets
# opened after the change. Same values as the long-standing manual tuning on the gateways.
#
{%- if grains.virtual != 'container'
      and ('dnsdist' in salt['pillar.get']('netbox:tag_list', [])
           or salt['pillar.get']('netbox:role:name') == 'parker-gateway') %}
{%- set buffers = {
  'net.core.rmem_default': 31457280,
  'net.core.rmem_max': 33554432,
  'net.core.wmem_default': 31457280,
  'net.core.wmem_max': 33554432,
  'net.core.netdev_max_backlog': 65536,
  'net.ipv4.udp_rmem_min': 16384,
  'net.ipv4.udp_wmem_min': 16384,
} %}
{#- optmem_max only on Parker gateways: it would change the value on the webfrontends #}
{%- if salt['pillar.get']('netbox:role:name') == 'parker-gateway' %}
{%- do buffers.update({'net.core.optmem_max': 25165824}) %}
{%- endif %}
{%- for key, value in buffers.items() %}
sysctl-buffers-{{ key }}:
  sysctl.present:
    - name: {{ key }}
    - value: {{ value }}
    - config: /etc/sysctl.d/10-tuning.conf
{%- endfor %}
{%- endif %}
