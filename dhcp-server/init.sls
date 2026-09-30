#
# DHCP server (for gateways)
#
# Gateways tagged 'dhcp-kea' in NetBox run Kea, all others still run
# isc-dhcp-server (unmaintained since 2022). Remove the tag to roll back.
#
{%- set tags = salt['config.get']('netbox:tag_list', []) %}
{%- set use_kea = 'dhcp-kea' in tags %}

# salt started complaining as this key is present in another formula...
netifaces-dhcp:
  pip.installed:  # Install into Salt's Python environment
    - name: netifaces

netaddr-dhcp:
  pip.installed:  # Install into Salt's Python environment
    - name: netaddr

{%- if use_kea %}
{#- Pinned like pdns-recursor/dnsdist; all Kea packages must share one
    version, the hooks check the Kea version they were built for. #}
{%- set kea_version = salt['config.get']('netbox:config_context:kea:version', '3.0.4-*') %}
{%- set vrf = 'vrf_external' in salt['grains.get']('ip_interfaces', {}) %}

isc-dhcp-server:
  service.dead:
    - enable: False
    - require_in:
      - service: kea-dhcp4

kea-repo-key:
  cmd.run:
    - name: "curl -fsSL https://dl.cloudsmith.io/public/isc/kea-3-0/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/isc-kea-3-0.gpg.tmp && mv /usr/share/keyrings/isc-kea-3-0.gpg.tmp /usr/share/keyrings/isc-kea-3-0.gpg"
    - unless: gpg --show-keys --with-colons /usr/share/keyrings/isc-kea-3-0.gpg 2>/dev/null | grep -q '^fpr:.*:9DA570BB192211885E4EB280B16C44CD45514C3C:'

kea-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/isc-kea-3-0.gpg] https://dl.cloudsmith.io/public/isc/kea-3-0/deb/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }} main
    - file: /etc/apt/sources.list.d/isc-kea-3-0.list
    - clean_file: True
    - require:
      - cmd: kea-repo-key

kea-packages:
  pkg.installed:
    - pkgs:
      - isc-kea-common: '{{ kea_version }}'
      - isc-kea-dhcp4: '{{ kea_version }}'
      - isc-kea-dhcp4-server: '{{ kea_version }}'
      - isc-kea-hooks: '{{ kea_version }}'
    - refresh: True
    - require:
      - pkgrepo: kea-repo

{%- if vrf %}

# Because of VRF support we run kea-dhcp4 through 'ip vrf exec', which needs
# root. Keep the _kea group so the control socket stays reachable for
# kea-pool-stats (telegraf, icinga).
/etc/systemd/system/isc-kea-dhcp4-server.service.d/vrf.conf:
  file.managed:
    - makedirs: True
    - contents: |
        # Managed by Salt
        [Service]
        User=root
        Group=_kea
        ExecStart=
        ExecStart=/sbin/ip vrf exec vrf_external /usr/sbin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf
    # in place before the package starts the service for the first time
    - require_in:
      - pkg: kea-packages
{%- else %}

/etc/systemd/system/isc-kea-dhcp4-server.service.d/vrf.conf:
  file.absent
{%- endif %}

kea-systemd-reload:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/isc-kea-dhcp4-server.service.d/vrf.conf
    - require_in:
      - pkg: kea-packages

# a reload (SIGHUP) does not apply a changed ExecStart
kea-restart-on-unit-change:
  cmd.run:
    - name: systemctl try-restart isc-kea-dhcp4-server
    - onchanges:
      - file: /etc/systemd/system/isc-kea-dhcp4-server.service.d/vrf.conf
    - require:
      - service: kea-dhcp4

/etc/kea/kea-dhcp4.conf:
  file.managed:
    - source: salt://dhcp-server/kea-dhcp4.conf.jinja
    - template: jinja
    - user: root
    - group: _kea
    - mode: "0640"
    - check_cmd: /usr/sbin/kea-dhcp4 -t
    - require:
      - pkg: kea-packages
      - pip: netifaces-dhcp
      - pip: netaddr-dhcp

kea-dhcp4:
  service.running:
    - name: isc-kea-dhcp4-server
    - enable: True
    - reload: True
    - require:
      - pkg: kea-packages
      - cmd: kea-systemd-reload
    - watch:
      - file: /etc/kea/kea-dhcp4.conf

# Pool statistics in the dhcpd-pools JSON format for telegraf and icinga
/usr/local/bin/kea-pool-stats:
  file.managed:
    - source: salt://dhcp-server/kea_pool_stats.py
    - mode: "0755"

{#- The control socket in /run/kea is only accessible for the _kea group. #}
{%- for user, service in [('telegraf', 'telegraf'), ('nagios', 'icinga2')] %}

kea-socket-access-{{ user }}:
  cmd.run:
    - name: usermod -aG _kea {{ user }} && systemctl try-restart {{ service }}
    - onlyif: id {{ user }}
    - unless: id -nG {{ user }} | grep -qw _kea
    - require:
      - pkg: kea-packages
{%- endfor %}

{%- else %}{# isc-dhcp-server #}

kea-dhcp4:
  service.dead:
    - name: isc-kea-dhcp4-server
    - enable: False
    - onlyif: systemctl cat isc-kea-dhcp4-server.service
    - require_in:
      - service: isc-dhcp-server

isc-dhcp-server:
  pkg.installed:
    - name: isc-dhcp-server
  service.running:
    - enable: True
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
{%- endif %}
