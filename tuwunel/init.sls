# Nightly RocksDB backup of Tuwunel (docker07): SIGUSR2 runs the stack's admin.signal_execute ("server backup-database"), rustic picks up backups/ at 03:00.
/etc/systemd/system/ffmuc-tuwunel-backup.service:
  file.managed:
    - source: salt://tuwunel/files/ffmuc-tuwunel-backup.service

/etc/systemd/system/ffmuc-tuwunel-backup.timer:
  file.managed:
    - source: salt://tuwunel/files/ffmuc-tuwunel-backup.timer

systemd-reload-ffmuc-tuwunel-backup:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-tuwunel-backup.service
      - file: /etc/systemd/system/ffmuc-tuwunel-backup.timer

ffmuc-tuwunel-backup-timer:
  service.running:
    - name: ffmuc-tuwunel-backup.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-tuwunel-backup
