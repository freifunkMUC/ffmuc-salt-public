#
# pdns-recursor
#

pdns-repo-key:
  cmd.run:
    - name: "curl https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor -o /usr/share/keyrings/powerdns-keyring.gpg"
    - creates: /usr/share/keyrings/powerdns-keyring.gpg

pdns-repo:
  pkgrepo.managed:
    - name: deb [arch=amd64 signed-by=/usr/share/keyrings/powerdns-keyring.gpg] http://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-rec-46 main
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
