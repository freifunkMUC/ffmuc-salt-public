#
# pdns-recursor
#

pdns-repo-key:
  cmd.run:
    - name: "/usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/trusted.gpg.d/FD380FBB.asc"
    - creates: /etc/apt/trusted.gpg.d/FD380FBB.asc

pdns-repo:
  pkgrepo.managed:
    - name: deb [arch=amd64] http://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-rec-49 main
    - file: /etc/apt/sources.list.d/pdns.list
    - clean_file: True
    - require:
      - cmd: pdns-repo-key

pdns-recursor:
  pkg.installed:
    - refresh: True
    - require:
      - pkgrepo: pdns-repo
  service.running:
    - enable: True
    - restart: True
    - require:
      - file: /etc/powerdns/recursor.conf
    - watch:
      - file: /etc/powerdns/recursor.conf

systemd-resolved:
  service.dead:
    - enable: False

/etc/powerdns/recursor.conf:
  file.managed:
    - source: salt://pdns-recursor/recursor.conf
    - template: jinja
