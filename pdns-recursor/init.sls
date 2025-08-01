#
# pdns-recursor
#

pdns-repo-key:
  cmd.run:
    - name: "/usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/trusted.gpg.d/FD380FBB.asc"
    - creates: /etc/apt/trusted.gpg.d/FD380FBB.asc

pdns-repo:
  pkgrepo.managed:
    - name: deb [arch=amd64] http://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-rec-52 main
    - file: /etc/apt/sources.list.d/pdns.list
    - clean_file: True
    - require:
      - cmd: pdns-repo-key

pdns-pkg:
  pkg.installed:
    - name: pdns-recursor
    - refresh: True
    - require:
      - pkgrepo: pdns-repo

/etc/powerdns/recursor.conf:
  file.managed:
    - source: salt://pdns-recursor/recursor.conf
    - template: jinja
    - require:
      - pkg: pdns-pkg

systemd-resolved:
  service.dead:
    - enable: False
    - requires:
      - pkg: pdns-pkg
      - file: /etc/powerdns/recursor.conf

/etc/resolv.conf:
  file.managed:
    - source: salt://pdns-recursor/resolv.conf
    - template: jinja
    - require:
      - service: systemd-resolved

pdns-recursor:
  service.running:
    - enable: True
    - restart: True
    - require:
      - pkg: pdns-pkg
      - file: /etc/powerdns/recursor.conf
      - service: systemd-resolved
    - watch:
      - file: /etc/powerdns/recursor.conf
