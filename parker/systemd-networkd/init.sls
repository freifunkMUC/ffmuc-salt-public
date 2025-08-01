{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:role:name')) %}

{%- if 'nextgen-gateway' in role %}
{%- set batman_version = '2024.1' %}
/usr/src/batman-adv-{{ batman_version }}:
  git.latest:
    - name: https://github.com/open-mesh-mirror/batman-adv.git
    - rev: v{{ batman_version }}
    - target: /usr/src/batman-adv-{{ batman_version }}
    - force_reset: True
    - require_in: /usr/src/batman-adv-{{ batman_version }}/dkms.conf

/usr/src/batman-adv-{{ batman_version }}/dkms.conf:
  file.managed:
    - contents: |
        PACKAGE_NAME=batman-adv
        PACKAGE_VERSION={{ batman_version }}

        DEST_MODULE_LOCATION=/extra
        BUILT_MODULE_NAME=batman-adv
        BUILT_MODULE_LOCATION=net/batman-adv

        MAKE="'make' KERNELPATH=${kernel_source_dir}"
        CLEAN="'make' clean"

        AUTOINSTALL="yes"
    - require_in: systemd-packages

# for gateways we need v249+ (not in Ubuntu 20.04 repos) to to configure Batman-Adv and FDB entries
{% if grains.os == 'Ubuntu' and grains.osmajorrelease < 24 %}
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
{% endif %}


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

{% endif %}{# 'nextgen-gateway' in role or 'parker-gateway' in role #}

{% if grains.os == 'Ubuntu' %}
disable_netplan:
  file.managed:
    - name: /etc/netplan/01-netcfg.yaml
    - source: salt://systemd-networkd/files/netplan.conf

disable_netplan_generator:
  file.symlink:
    - name: /usr/lib/systemd/system-generators/netplan
    - target: /dev/null
    - force: True
{% endif %}

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

{# In case of Parker, add crosslink interfaces #}
{% if 'parker-gateway' in role %}

{% for node,_ in salt['mine.get']('netbox:role:name:parker-gateway', 'minion_id', tgt_type='pillar').items() | sort %}
{%- if grains['id'] not in node %}{# Skip, don't create peer for the host we are configuring #}

{%- set peer_wireguard_public_key = salt['mine.get'](node,'minion_wireguard_public', tgt_type='glob')[node] %}

{%- set port_config = salt['pillar.get']('netbox:config_context:parker_backbone_config:wg_ports') %}
{# Port concept: each gateway gets assigned one port.
    This port will be used as the listen port on all other gateways on the interface connecting with this gateway.
    This means that "this" gateway uses the port of the respective peer as listen address on each interface.
    And as endpoint port for the single peer on each interface this gateway uses "its own" port. #}
{%- set listen_port = port_config[node] %}{# as _local_ listen port we take a port specified under the peer #}
{%- set peer_port = port_config[grains['id']] %}{# as _remote_ port we take the port specified for our own #}

{%- set peer_link_local = salt['wireguard_v6.generate'](peer_wireguard_public_key) %}
{%- set peer_endpoint = (node | regex_replace('in\.ffmuc\.net','ext.ffmuc.net')) + ":" + (peer_port | string) %}

{% set node_short = node | regex_replace('in\.ffmuc\.net','') %}
 {# TODO ipaddresses #}
{% set iface = {
  "wg-bb-" + node_short: {
    "description": "Crosslink to " + node_short,
    "ipaddresses": [],
    "listen_port": listen_port,
    "peer_public_key": peer_wireguard_public_key,
    "peer_link_local": peer_link_local,
    "peer_endpoint": peer_endpoint,
} } %}
{%- do interfaces.update(iface) %}
{%- endif %}{# if grains['id'] not in node #}
{% endfor %}{# for node,_ #}
{%- endif %}{# if parker-gateway in role #}


{%- set gateway = salt['pillar.get']('netbox:config_context:network:gateway') %}
{% for iface in interfaces |sort %}
{% if "nebula" not in iface %}
{% if 'mac_address' in interfaces[iface] and interfaces[iface]['mac_address'] is not none %}
/etc/systemd/network/10-{{ iface }}.link:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-link.jinja2
    - template: jinja
      interface: {{ iface }}
      mac: {{ interfaces[iface]['mac_address'] }}
      desc: "{{ interfaces[iface]['description'] }}"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: generate_initrd
      - cmd: systemd-networkd-reload
{% endif %}

{% set id = 10 %}
# Are we creating a dummy interface? So we also need a netdev file
{% if "dummy" in iface %}
/etc/systemd/network/20-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      kind: "dummy"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 20 %}
{% elif "wg" in iface %}
/etc/systemd/network/30-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      {% if 'parker-gateway' in role and 'wg-bb-' in iface %}
      ipaddresses:  {{ interfaces[iface]['ipaddresses'] }}
      listen_port: {{ interfaces[iface]['listen_port'] }}
      peer_public_key: {{ interfaces[iface]['peer_public_key'] }}
      peer_link_local: {{ interfaces[iface]['peer_link_local'] }}
      peer_endpoint: {{ interfaces[iface]['peer_endpoint'] }}
      {% endif %}
      kind: "wireguard"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 30 %}
{% elif "vx" in iface %}
/etc/systemd/network/40-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      kind: "vxlan"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 40 %}
{% elif "bat" in iface %}
/etc/systemd/network/50-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      kind: "batadv"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 50 %}
{% elif "br" in iface %}ipaddresses
/etc/systemd/network/60-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      kind: "bridge"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 60 %}
{% elif "ip6gre" in iface %}
/etc/systemd/network/70-{{ iface }}.netdev:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-netdev.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      kind: "ip6gre"
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% set id = 70 %}
{% endif %}
# Generate network files for each interface we have in netbox
/etc/systemd/network/{{ id }}-{{ iface }}.network:
  file.managed:
    - source: salt://parker/systemd-networkd/files/systemd-network.jinja2
    - template: jinja
      interface: {{ iface }}
      desc: "{{ interfaces[iface]['description'] }}"
      ipaddresses: {{ interfaces[iface]['ipaddresses'] }}
      gateway: {{ gateway }}
    - user: systemd-network
    - group: systemd-network
    - mode: "0600"
    - watch_in:
      - cmd: systemd-networkd-reload
{% endif %}
{% endfor %}
