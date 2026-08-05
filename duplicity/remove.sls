
duplicity:
  pkg.removed

remove_duplicity_files:
  file.absent:
    - names:
        - /usr/share/keyrings/duplicity-team-keyring.gpg
        - /etc/apt/sources.list.d/duplicity.list
        - /usr/local/sbin/backup.sh
        - /etc/systemd/system/ffmuc-backup.service
        - /etc/systemd/system/ffmuc-backup.timer
    - require:
      - service: ffmuc-backup-timer-disable
      - pkg: duplicity

systemd-reload-ffmuc-backup:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: remove_duplicity_files


ffmuc-backup-timer-disable:
  service.dead:
    - name: ffmuc-backup.timer
    - enable: false
