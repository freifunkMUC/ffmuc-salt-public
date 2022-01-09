{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:device_role:name')) %}

{%- if 'nextgen-gateway' in role %}
/usr/src/batman-adv-2021.5/dkms.conf:
  file.managed:
    - contents: |
        PACKAGE_NAME=batman-adv
        PACKAGE_VERSION=2021.5

        DEST_MODULE_LOCATION=/extra
        BUILT_MODULE_NAME=batman-adv
        BUILT_MODULE_LOCATION=net/batman-adv

        MAKE="'make' KERNELPATH=${kernel_source_dir}"
        CLEAN="'make' clean"

        AUTOINSTALL="yes"
    - require_in: systemd-packages

# for gateways we need v249+ (not in upstream yet) to to configure Batman-Adv and FDB entries
{% set systemd_nightly_buildid = "21960774" %}
{% set systemd_version = "249.287.g84817bfdb3+20.04.20210808175006" %}
systemd-packages:
  pkg.installed:
    - sources:
{% for package in [
  "libnss-systemd",
  "libpam-systemd",
  "libsystemd0",
  "libudev1",
  "systemd-sysv",
  "systemd",
  "udev"
] %}
    #- {{ package }}: https://code.launchpad.net/~ubuntu-support-team/+archive/ubuntu/systemd/+build/{{ systemd_nightly_buildid }}/+files/{{ package }}_{{ systemd_version }}_{{ grains.osarch }}.deb
      - {{ package }}: https://apt.ffmuc.net/systemd-packages/{{ package }}_{{ systemd_version }}_{{ grains.osarch }}.deb
{% endfor %}{# packages #}

/etc/systemd/system/batadv-throughput.service:
  file.managed:
    - source: salt://systemd-networkd/files/batadv-throughput.service

/usr/local/bin/batadv-througput.sh:
  file.managed:
    - source: salt://systemd-networkd/files/batadv-throughput.sh
    - mode: "0750"

systemd-reload-batadv-throughput:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/batadv-throughput.service

batadv-throughput.service:
  service.enabled:
    - require:
      - file: /etc/systemd/system/batadv-throughput.service

# workaround until https://github.com/systemd/systemd/issues/20305 is fixed
/usr/local/bin/vxlan-fdb-fill.sh:
  file.absent

/etc/systemd/system/vxlan-fdb-fill.service:
  file.absent

systemd-reload-vxlan-fdb-fill:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/vxlan-fdb-fill.service

vxlan-fdb-fill.service:
  service.disabled

{% endif %}{# 'nextgen-gateway' in role #}

disable_netplan:
    file.managed:
        - name: /etc/netplan/01-netcfg.yaml
        - source: salt://systemd-networkd/files/netplan.conf

systemd-networkd:
    service.running:
        - enable: True
        - running: True

generate_initrd:
    cmd.wait:
        - name: update-initramfs -k all -u
        - watch: []

systemd-networkd-reload:
  cmd.run:
    - name: networkctl reload
    - runas: root
    - onchanges: []
    - require:
      - service: systemd-networkd

# Rename interfaces to corresponding vlans based on mac address
{%- set interfaces = salt['pillar.get']('netbox:interfaces') %}
{%- set gateway = salt['pillar.get']('netbox:config_context:network:gateway') %}
{% for iface in interfaces |sort %}
{% if "nebula" not in iface %}
{% if 'mac_address' in interfaces[iface] and interfaces[iface]['mac_address'] is not none %}
/etc/systemd/network/10-{{ iface }}.link:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-link.jinja2
    - template: jinja
      interface: {{ iface }}
      mac: {{ interfaces[iface]['mac_address'] }}
      desc: {{ interfaces[iface]['description'] }}
    - watch_in:
      - cmd: generate_initrd
      - cmd: systemd-networkd-reload
{% endif %}

{% set id = 10 %}
# Are we creating a dummy interface? So we also need a netdev file
{% if "dummy" in iface %}
/etc/systemd/network/20-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "dummy"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 20 %}
{% elif "wg" in iface %}
/etc/systemd/network/30-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "wireguard"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 30 %}
{% elif "vx" in iface %}
/etc/systemd/network/40-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "vxlan"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 40 %}
{% elif "bat" in iface %}
/etc/systemd/network/50-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "batadv"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 50 %}
{% elif "br" in iface %}
/etc/systemd/network/60-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "bridge"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 60 %}
{% elif "ip6gre" in iface %}
/etc/systemd/network/70-{{ iface }}.netdev:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      kind: "ip6gre"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 70 %}
{% endif %}
# Generate network files for each interface we have in netbox
/etc/systemd/network/{{ id }}-{{ iface }}.network:
  file.managed:
    - source: salt://systemd-networkd/files/systemd-network.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: {{ interfaces[iface]['description'] }}
      ipaddresses: {{ interfaces[iface]['ipaddresses'] }}
      gateway: {{ gateway }}
    - watch_in:
      - cmd: systemd-networkd-reload
{% endif %}
{% endfor %}

