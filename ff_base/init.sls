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
{% if grains.os == 'Ubuntu' and grains.osmajorrelease >= 24 %}
      - iptraf-ng
      - plocate
{% else %}
      - iptraf
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

bandwidth-monitor-repo-key:
  cmd.run:
    - name: "curl -fsSL https://awlx.github.io/bandwidth-monitor/bandwidth-monitor.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/bandwidth-monitor.gpg"
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
    - version: '0.0.34'
    - require:
      - pkgrepo: bandwidth-monitor-repo
