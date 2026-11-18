{#- One Salt version on master and minions, pinned (Broadcom's advice): Renovate bumps it with the master image
    (stacks/docker05/salt-master) in one PR, group "Salt". Hosts without the package layout (Raspbian, guardians with an own
    unit until `guardian-trixie.sh pkgs`) are left alone. #}
{#- renovate: datasource=docker depName=ghcr.io/cdalvaro/docker-salt-master #}
{%- set salt_version = '3008.5' %}
{%- if grains.os != 'Raspbian' and not salt['file.file_exists']('/etc/systemd/system/salt-minion.service') %}
/etc/apt/preferences.d/salt-pin-1001:
  file.managed:
    - contents: |
        Package: salt-*
        Pin: version {{ salt_version }}
        Pin-Priority: 1001

# apt restarts the minion: install outside this job so the state run still returns
salt-minion-upgrade:
  cmd.run:
    - name: systemd-run --on-active=15 --collect --unit=salt-minion-upgrade sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Options::=--force-confold salt-minion={{ salt_version }} salt-common={{ salt_version }}'
    - unless: test "$(dpkg-query -W -f='${Version}' salt-minion 2>/dev/null)" = "{{ salt_version }}"
    - require:
      - file: /etc/apt/preferences.d/salt-pin-1001
{%- endif %}

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

# The reconnect drop-in (#693) gained nothing on jvb14 (41 s without, 42 s with); remove it where it was applied.
{%- for unit in ['nebula', 'nebula-meet'] %}
/etc/systemd/system/{{ unit }}.service.d/salt-minion-reconnect.conf:
  file.absent
{%- endfor %}

salt-minion-reconnect-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/nebula.service.d/salt-minion-reconnect.conf
      - file: /etc/systemd/system/nebula-meet.service.d/salt-minion-reconnect.conf
