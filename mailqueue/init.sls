#
# Mail queue snapshot for Icinga (mail01): a root timer writes count and age of
# the queue to /var/lib/icinga2/mailqueue.state, check_ffmuc_mailqueue reads it.
#
/usr/local/sbin/ffmuc-mailqueue-snapshot:
  file.managed:
    - source: salt://mailqueue/files/ffmuc-mailqueue-snapshot
    - mode: "0755"

/etc/systemd/system/ffmuc-mailqueue.service:
  file.managed:
    - source: salt://mailqueue/files/ffmuc-mailqueue.service

/etc/systemd/system/ffmuc-mailqueue.timer:
  file.managed:
    - source: salt://mailqueue/files/ffmuc-mailqueue.timer

systemd-reload-ffmuc-mailqueue:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-mailqueue.service
      - file: /etc/systemd/system/ffmuc-mailqueue.timer

ffmuc-mailqueue-timer:
  service.running:
    - name: ffmuc-mailqueue.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-mailqueue
      - file: /usr/local/sbin/ffmuc-mailqueue-snapshot
