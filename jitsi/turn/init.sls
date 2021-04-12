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
    - contents: |
        [Service]
        AmbientCapabilities=CAP_NET_BIND_SERVICE

systemd-reload-coturn:
  cmd.run:
   - name: systemctl --system daemon-reload
   - onchanges:  
     - file: /etc/systemd/system/coturn.service.d/override.conf