#
# DHCP server for the guardians (guardian-*): Kea from Raspbian instead of
# isc-dhcp-server. Opt-in by the NetBox config context `dhcp_guardian`:
#   absent             nothing is touched (dhcpd.conf stays hand-managed)
#   enabled: true      Kea runs, isc-dhcp-server is stopped and disabled
#   enabled: false     rollback: Kea stopped and disabled, isc-dhcp-server runs
# Not purged either way, so the switch is reversible by hand as well:
#   systemctl disable --now kea-dhcp4-server && systemctl enable --now isc-dhcp-server
#
{%- set cfg = salt['config.get']('netbox:config_context:dhcp_guardian', none) %}
{%- if cfg is mapping %}
{%- if cfg.get('enabled', False) %}

kea-dhcp4-guardian-package:
  pkg.installed:
    - name: kea-dhcp4-server

# check_cmd runs kea-dhcp4 -t on the new file before it replaces the old one;
# if it fails, nothing below runs and dhcpd keeps serving.
/etc/kea/kea-dhcp4.conf:
  file.managed:
    - source: salt://dhcp-server/kea-dhcp4-guardian.conf.jinja
    - template: jinja
    - user: root
    - group: _kea
    - mode: "0640"
    - check_cmd: /usr/sbin/kea-dhcp4 -t
    - require:
      - pkg: kea-dhcp4-guardian-package

isc-dhcp-server:
  service.dead:
    - enable: False
    - require:
      - file: /etc/kea/kea-dhcp4.conf
    - require_in:
      - service: kea-dhcp4-server

kea-dhcp4-server:
  service.running:
    - enable: True
    - require:
      - pkg: kea-dhcp4-guardian-package
    - watch:
      - file: /etc/kea/kea-dhcp4.conf
{%- else %}

kea-dhcp4-server:
  service.dead:
    - enable: False
    - onlyif: systemctl cat kea-dhcp4-server.service
    - require_in:
      - service: isc-dhcp-server

isc-dhcp-server:
  service.running:
    - enable: True
{%- endif %}
{%- else %}

dhcp-guardian-not-configured:
  test.nop:
    - name: no dhcp_guardian config context, DHCP left as it is
{%- endif %}
