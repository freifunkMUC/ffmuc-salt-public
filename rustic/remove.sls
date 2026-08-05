

/usr/local/bin/rustic:
  file.absent

/root/.config/rustic/rustic.toml:
  file.absent

/usr/local/sbin/rustic-backup.sh:
  file.absent

ffmuc-backup-timer:
  service.dead:
    - name: ffmuc-rustic-backup.timer
    - enable: false

/etc/systemd/system/ffmuc-rustic-backup.service:
  file.absent:
    - require:
      - service: ffmuc-backup-timer

/etc/systemd/system/ffmuc-rustic-backup.timer:
  file.absent:
    - require:
      - service: ffmuc-backup-timer

systemd-reload-ffmuc-backup:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-rustic-backup.service
      - file: /etc/systemd/system/ffmuc-rustic-backup.timer
    - require:
      - file: /etc/systemd/system/ffmuc-rustic-backup.service
      - file: /etc/systemd/system/ffmuc-rustic-backup.timer
