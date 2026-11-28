# Etherpad pads (Meet) without changes for 180 days are deleted daily (docker04, MariaDB store table).
/usr/local/sbin/ffmuc-etherpad-retention:
  file.managed:
    - source: salt://etherpad-retention/files/ffmuc-etherpad-retention
    - mode: '0755'

{%- for unit in ["service", "timer"] %}
/etc/systemd/system/ffmuc-etherpad-retention.{{ unit }}:
  file.managed:
    - source: salt://etherpad-retention/files/ffmuc-etherpad-retention.{{ unit }}
{%- endfor %}

systemd-reload-ffmuc-etherpad-retention:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-etherpad-retention.service
      - file: /etc/systemd/system/ffmuc-etherpad-retention.timer

ffmuc-etherpad-retention-timer:
  service.running:
    - name: ffmuc-etherpad-retention.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-etherpad-retention
    - watch:
      - file: /etc/systemd/system/ffmuc-etherpad-retention.timer
