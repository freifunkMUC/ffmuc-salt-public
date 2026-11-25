# Wazuh manager alert/archive files older than 90 days (docker07), matching the indexer's 90-day ISM policy.
/usr/local/sbin/ffmuc-wazuh-log-retention:
  file.managed:
    - source: salt://wazuh-retention/files/ffmuc-wazuh-log-retention
    - mode: '0755'

{%- for unit in ["service", "timer"] %}
/etc/systemd/system/ffmuc-wazuh-log-retention.{{ unit }}:
  file.managed:
    - source: salt://wazuh-retention/files/ffmuc-wazuh-log-retention.{{ unit }}
{%- endfor %}

systemd-reload-ffmuc-wazuh-log-retention:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-wazuh-log-retention.service
      - file: /etc/systemd/system/ffmuc-wazuh-log-retention.timer

ffmuc-wazuh-log-retention-timer:
  service.running:
    - name: ffmuc-wazuh-log-retention.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-wazuh-log-retention
    - watch:
      - file: /etc/systemd/system/ffmuc-wazuh-log-retention.timer
