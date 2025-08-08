#
# sysctl
#

{%- if grains.virtual != 'container' %}

include:
  - sysctl.global

#
# Activate IP Unicast Routing
net.ipv4.ip_forward:
  sysctl.present:
    - value: 1
    - config: /etc/sysctl.d/21-forwarding.conf

net.ipv6.conf.all.forwarding:
  sysctl.present:
    - value: 1
    - config: /etc/sysctl.d/21-forwarding.conf

{%- endif %}

{# Remove old files #}
{% for file in ['20-arp_caches.conf', '21-ip_forward.conf', '22-kernel.conf', 'NAT.conf', 'nf-ignore-bridge.conf', 'global.conf', 'router.conf'] %}
/etc/sysctl.d/{{ file }}:
  file.absent
{% endfor %}

