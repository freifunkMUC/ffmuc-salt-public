#
# Ubuntu: Salt writes the systemd-networkd files, netplan must not.
# Included by systemd-networkd and parker.systemd-networkd.
#
{%- if grains.os == 'Ubuntu' %}

disable_netplan:
  file.managed:
    - name: /etc/netplan/01-netcfg.yaml
    - source: salt://systemd-networkd/files/netplan.conf
    - mode: "0600"

# The installer config has a default route via the management VLAN.
/etc/netplan/00-installer-config.yaml:
  file.absent

disable_netplan_generator:
  file.symlink:
    - name: /usr/lib/systemd/system-generators/netplan
    - target: /dev/null
    - force: True

# netplan >= 1.2 (Ubuntu 26.04) writes /run/systemd/network/10-netplan-* at
# boot with this service, not with the generator. These files sort before
# the Salt files and networkd then ignores the Salt files. 24.04 (netplan 1.1)
# has no such unit: no-op there.
netplan-configure.service:
  service.masked:
    - onlyif: test -e /usr/lib/systemd/system/netplan-configure.service

remove_netplan_runtime_files:
  cmd.run:
    - name: rm -f /run/systemd/network/10-netplan-*
    - onlyif: ls /run/systemd/network/10-netplan-* >/dev/null 2>&1
    - require:
      - file: disable_netplan_generator
      - service: netplan-configure.service
    - watch_in:
      - cmd: systemd-networkd-reload

# The installer netplan config uses DHCP. networkd adds a default route and
# /32 routes to the DHCP DNS servers (RoutesToDNS). After the switch to the
# Salt files these routes stay, because ManageForeignRoutes=no
# (systemd-networkd.foreign-routes). A stale /32 route to a public DNS server
# sends that traffic to the management VLAN. Remove the routes if no Salt
# network file uses DHCP.
remove_stale_dhcp_routes:
  cmd.run:
    - name: ip -4 route flush proto dhcp
    - onlyif: ip -4 route show proto dhcp | grep -q .
    - unless: grep -qsE '^DHCP=(yes|true|ipv4|both)' /etc/systemd/network/*.network
    - require:
      - cmd: systemd-networkd-reload
{%- endif %}
