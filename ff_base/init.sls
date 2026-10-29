#
# Stuff for every FFMUC machine
#

ffmuc_packages:
  pkg.installed:
    - pkgs:
      - git
      - openssl
      - netcat-openbsd
      - htop
      - tcpdump
      - pv
      - wget
      - iftop
      - screen
      - ethtool
      - mtr-tiny
      - lldpd
      - sysstat
      - dnsutils
      - curl
      - iptraf-ng
{% if grains.os == 'Ubuntu' and grains.osmajorrelease >= 24 %}
      - plocate
{% else %}
      - mlocate
{% endif %}
      - speedtest-cli
      - dmidecode
      - psmisc
      - lshw
      - jq

ffmuc_removed_packages:
  pkg.removed:
    - pkgs:
      - postfix
      - rpcbind

/etc/apt/keyrings:
  file.directory:
    - makedirs: True

{%- if grains.osarch in ['amd64', 'arm64'] %}
{#- the bandwidth-monitor repo builds amd64 and arm64 only #}
bandwidth-monitor-repo-key:
  cmd.run:
    - name: "curl -fsSL https://awlx.github.io/bandwidth-monitor/bandwidth-monitor.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/bandwidth-monitor.gpg.tmp && mv /etc/apt/keyrings/bandwidth-monitor.gpg.tmp /etc/apt/keyrings/bandwidth-monitor.gpg"
    - require:
      - file: /etc/apt/keyrings

bandwidth-monitor-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/etc/apt/keyrings/bandwidth-monitor.gpg] https://awlx.github.io/bandwidth-monitor stable main
    - file: /etc/apt/sources.list.d/bandwidth-monitor.list
    - clean_file: True
    - require:
      - cmd: bandwidth-monitor-repo-key

bandwidth-top:
  pkg.installed:
    - version: '0.0.36'
    - require:
      - pkgrepo: bandwidth-monitor-repo
{%- endif %}

{#- KVM guests on the vm-hosts: every domain has the guest agent channel, and a serial console on ttyS0 #}
{%- if grains.get('virtual') == 'kvm' %}
qemu-guest-agent:
  pkg.installed: []
  # the unit is static and started by udev for the virtio port; running is enough
  service.running:
    - require:
      - pkg: qemu-guest-agent

# kernel and GRUB on the serial console as well, so `virsh console` shows boot problems
/etc/default/grub.d/90-ffmuc-serial-console.cfg:
  file.managed:
    - makedirs: True
    - mode: "0644"
    - contents: |
        # serial console for `virsh console` on the vm-host (Salt, ff_base)
        GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} console=tty0 console=ttyS0,115200n8"
        GRUB_TERMINAL="console serial"
        GRUB_SERIAL_COMMAND="serial --speed=115200"

update-grub-serial-console:
  cmd.run:
    - name: update-grub
    - onchanges:
      - file: /etc/default/grub.d/90-ffmuc-serial-console.cfg
{%- endif %}
