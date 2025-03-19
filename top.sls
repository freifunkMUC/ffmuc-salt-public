base:
  # Base config for all minions
  '*':
    - bash
    - fail2ban
    - ff_base
    - graylog-sidecar
    - locales
    - logrotate
    - mosh
    - motd
    - nebula
    - screen
    - sudo
    - sysctl
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
    - duplicity
    - grafana
    - icinga2
    - influxdb
    - jenkins
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
#    - nginx # broken, old nginx versions
  'call*':
    - jitsi.asterisk
    - jitsi.jigasi
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
  'vpn0*.in.ffmuc.net':
    - wireguard
