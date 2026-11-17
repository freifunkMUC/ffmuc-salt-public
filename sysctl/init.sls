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

{%- else %}

# unprivileged containers: systemd's default 0-2147483647 exceeds the gid map,
# leaving 65534 and no unprivileged ICMP sockets (icinga ping checks fail)
net.ipv4.ping_group_range:
  sysctl.present:
    - value: 0 65535
    - config: /etc/sysctl.d/10-ping-group.conf

{%- endif %}

{# Remove old files #}
{% for file in ['20-arp_caches.conf', '21-ip_forward.conf', '22-kernel.conf', 'NAT.conf', 'nf-ignore-bridge.conf', 'global.conf', 'router.conf'] %}
/etc/sysctl.d/{{ file }}:
  file.absent
{% endfor %}

