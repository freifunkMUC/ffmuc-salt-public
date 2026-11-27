{#- UniFi OS Server (Ubiquiti) in rootful Podman on unifi-os. First install only: afterwards UniFi OS updates itself (uosserver-updater);
    the Network app's auto-update is a UI step (Settings, Control Plane, Updates), nothing here can set it. Back up first, then update by hand.
    Latest: https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~linux-x64 #}
{%- set uos_url = "https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64" %}
{%- set uos_hash = "f6111e9396a42c74016f5dde9b01fbef486a6fe69efe137935e6e38b7c22f94d" %}
{%- set swap_mb = 2048 %}
{%- set installed = "test -x /usr/local/bin/uosserver" %}

unifi-os-server-packages:
  pkg.installed:
    - pkgs:
      - podman
      - slirp4netns
      - passt
      - uidmap
      - qemu-guest-agent

# needs the virtio port, i.e. the channel in the domain XML (present on all vm-host guests)
qemu-guest-agent:
  service.running:
    - onlyif: test -e /dev/virtio-ports/org.qemu.guest_agent.0
    - require:
        - pkg: unifi-os-server-packages

# Ubiquiti asks for 2 GB swap; the cloud image has none
unifi-os-server-swapfile:
  cmd.run:
    - name: fallocate -l {{ swap_mb }}M /swapfile.new && chmod 600 /swapfile.new && mkswap /swapfile.new && mv /swapfile.new /swapfile
    - creates: /swapfile

# persist: true writes the fstab line and runs swapon
/swapfile:
  mount.swap:
    - persist: True
    - require:
        - cmd: unifi-os-server-swapfile

unifi-os-server-installer:
  file.managed:
    - name: /var/tmp/unifi-os-server-installer
    - source: {{ uos_url }}
    - source_hash: sha256={{ uos_hash }}
    - mode: "0700"
    - unless: {{ installed }}

# asks once "Proceed? (y/N)", there is no unattended flag
unifi-os-server-install:
  cmd.run:
    - name: printf 'y\n' | /var/tmp/unifi-os-server-installer
    - shell: /bin/bash
    - creates: /usr/local/bin/uosserver
    - require:
        - pkg: unifi-os-server-packages
        - mount: /swapfile
        - file: unifi-os-server-installer

unifi-os-server-installer-absent:
  file.absent:
    - name: /var/tmp/unifi-os-server-installer
    - require:
        - cmd: unifi-os-server-install

{%- for unit in ["uosserver", "uosserver-updater"] %}

{{ unit }}:
  service.running:
    - enable: True
    - require:
        - cmd: unifi-os-server-install
{%- endfor %}
