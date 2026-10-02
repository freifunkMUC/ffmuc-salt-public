# duplicity was replaced by rustic. Removes the package, the old backup
# script and the ffmuc-backup timer that duplicity/disable.sls kept running.

duplicity:
  pkg.removed:
    - require:
      - service: ffmuc-backup-service-stop

remove_duplicity_files:
  file.absent:
    - names:
        - /usr/share/keyrings/duplicity-team-keyring.gpg
        - /etc/apt/sources.list.d/duplicity.list
        - /usr/local/sbin/backup.sh
        - /etc/systemd/system/ffmuc-backup.service
        - /etc/systemd/system/ffmuc-backup.timer
    - require:
      - service: ffmuc-backup-service-stop
      - pkg: duplicity

systemd-reload-duplicity-removed:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: remove_duplicity_files


ffmuc-backup-timer-disable:
  service.dead:
    - name: ffmuc-backup.timer
    - enable: false

# stopping the timer does not stop a backup/prune run it already started
ffmuc-backup-service-stop:
  service.dead:
    - name: ffmuc-backup.service
    - require:
      - service: ffmuc-backup-timer-disable
