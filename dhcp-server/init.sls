#
# DHCP server (for gateways)
#

# salt started complaining as this key is present in another formula...
netifaces-dhcp:
  pip.installed:  # Install into Salt's Python environment
    - name: netifaces

netaddr-dhcp:
  pip.installed:  # Install into Salt's Python environment
    - name: netaddr

isc-dhcp-server:
  pkg.installed:
    - name: isc-dhcp-server
  service.running:
    - enable: True
    - restart: True
    - require:
      - file: /etc/systemd/system/isc-dhcp-server.service
      - file: /var/lib/dhcp/dhcpd.leases
    - watch:
      - file: /etc/dhcp/dhcpd.conf

/var/lib/dhcp/dhcpd.leases:
  file.managed:
    - user: root
    - group: root

dhcpd-pools:
  pkg.installed:
    - name: dhcpd-pools

# Because of VRF support we override the default start script
/etc/systemd/system/isc-dhcp-server.service:
  file.managed:
    - source: salt://dhcp-server/isc-dhcp-server.service
    - template: jinja

/etc/dhcp/dhcpd.conf:
  file.managed:
    - source: salt://dhcp-server/dhcpd.conf
    - template: jinja
    - require:
      - file: /etc/systemd/system/isc-dhcp-server.service
      - pip: netifaces-dhcp
      - pip: netaddr-dhcp
    - watch_in:
      - service: isc-dhcp-server

