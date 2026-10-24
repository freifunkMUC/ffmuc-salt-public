base:
  # Base config for all minions
  '*':
    - bash
    - ca-distrust
    # duplicity was replaced by rustic; drop once all hosts are cleaned up
    - duplicity.remove
    - fail2ban
    - ff_base
    - graylog-sidecar
    - locales
    - logrotate
    - mosh
    - motd
    - nebula
    - needrestart
    - resolv
    - screen
    - sudo
    - sysctl
    - systemd-networkd.foreign-routes
    - telegraf
    - timezone
    - tmux
    - unattended-upgrades
    - vim
    - ssh
  '*.in.ffmuc.net':
    - apt
    - certs
    - docker
    - dphys-swapfile
    - rustic
    - grafana
    - icinga2
    - influxdb
    - komodo-periphery
    - kvm
    - ntp
    - snmpd
  '*.meet.ffmuc.net':
    - nebula-meet
    - jitsi.base
    - jitsi.jibri
    - jitsi.videobridge
  'jicofo*.meet.ffmuc.net':
    - jitsi.prosody
    - jitsi.jicofo
    - jitsi.meet
    - certs
    - jitsi.nginx
  'call*':
    - jitsi.asterisk
    - jitsi.jigasi
    - jitsi.vosk
  'gw*':
    - dhcp-server
    - knot-resolver.remove
    - pdns-recursor
    - radvd
    - respondd
    - systemd-networkd
#  'webfrontend03.in.ffmuc.net':
#    - cloudflare
  'webfrontend0[3-6].in.ffmuc.net':
    - dns-auth
    - pdns-recursor
    - github-downloader
  'guardian-*.in.ffmuc.net':
    - sflowtool
  'vpn0*.in.ffmuc.net':
    - wireguard
