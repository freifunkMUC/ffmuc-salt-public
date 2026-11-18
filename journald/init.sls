#
# journald
#
# Limit the persistent journal size. Without a limit, journald may use up to
# 10% of the filesystem (max 4G), which fills small root disks.
#

/etc/systemd/journald.conf.d/50-ffmuc.conf:
  file.managed:
    - source: salt://journald/50-ffmuc.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: "0644"

systemd-journald-restart:
  cmd.run:
    - name: systemctl restart systemd-journald
    - onchanges:
      - file: /etc/systemd/journald.conf.d/50-ffmuc.conf
