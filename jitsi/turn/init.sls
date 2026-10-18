###
# Turnserver
###

coturn:
  pkg.installed:
    - name: coturn
  service.running:
    - enable: True

/etc/turnserver.conf:
  file.managed:
    - source: salt://jitsi/turn/turnserver.conf.jinja
    - template: jinja
    - require:
      - pkg: coturn
    - watch_in:
      - service: coturn

/etc/systemd/system/coturn.service.d/override.conf:
  file.managed:
    - makedirs: true
    - contents: |
        [Service]
        AmbientCapabilities=CAP_NET_BIND_SERVICE

systemd-reload-coturn:
  cmd.run:
   - name: systemctl --system daemon-reload
   - onchanges:
     - file: /etc/systemd/system/coturn.service.d/override.conf

/etc/rsyslog.d/turnserver.conf:
  file.managed:
    - contents: |
        # Managed by Salt
        # avoid turnserver logs to fill multiple files
        :programname,isequal,"turnserver"         /var/log/turnserver.log
        & stop

/etc/logrotate.d/turnserver:
  file.managed:
    - contents: |
        # Managed by Salt
        /var/log/turnserver.log
        {
                su root syslog
                rotate 7
                daily
                missingok
                notifempty
                compress
                delaycompress
                postrotate
                        /usr/lib/rsyslog/rsyslog-rotate
                endscript
        }
