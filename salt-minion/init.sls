# Notice a dead master connection in about a minute instead of ~7 (Nebula restarts leave half-open sockets).
/etc/salt/minion.d/tcp-keepalive.conf:
  file.managed:
    - contents: |
        tcp_keepalive: True
        tcp_keepalive_idle: 30
        tcp_keepalive_intvl: 10
        tcp_keepalive_cnt: 3

# Delayed, so this state run still returns to the master before the minion restarts.
salt-minion-restart-keepalive:
  cmd.run:
    - name: systemd-run --on-active=15 systemctl restart salt-minion
    - onchanges:
      - file: /etc/salt/minion.d/tcp-keepalive.conf

# A Nebula restart empties its conntrack; the master's packets are then dropped (no inbound rule) and its TCP
# retransmits back off to minutes. Reconnect the minion shortly after every Nebula start (delayed: a running job returns first).
{%- for unit in ['nebula', 'nebula-meet'] %}
/etc/systemd/system/{{ unit }}.service.d/salt-minion-reconnect.conf:
  file.managed:
    - makedirs: True
    - contents: |
        [Service]
        ExecStartPost=-/usr/bin/systemd-run --on-active=15 /bin/systemctl restart salt-minion
{%- endfor %}

salt-minion-reconnect-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/nebula.service.d/salt-minion-reconnect.conf
      - file: /etc/systemd/system/nebula-meet.service.d/salt-minion-reconnect.conf
