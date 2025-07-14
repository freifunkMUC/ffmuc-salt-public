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
