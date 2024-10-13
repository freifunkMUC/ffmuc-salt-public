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
      - plocate
      - sysstat
      - dnsutils
      - curl
      - iptraf
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
