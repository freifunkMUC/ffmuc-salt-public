###
# Telegraf
###

{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
{% if "telegraf" in tags %}

{# There is data available so we think telegraf should be installed #}
{% set role = salt['pillar.get']('netbox:role:name') %}

influx-db-repo-key:
  cmd.run:
    - name: "curl https://repos.influxdata.com/influxdata-archive_compat.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/influxdb-keyring.gpg"

influx-db-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/influxdb-keyring.gpg] https://repos.influxdata.com/{{ grains.lsb_distrib_id | lower }} stable main
    - file: /etc/apt/sources.list.d/influxdb.list
    - clean_file: True
    - require:
      - cmd: influx-db-repo-key

telegraf:
  pkg.installed:
    - require:
        - pkgrepo: influx-db-repo
  service.running:
    - enable: True
    - running: True

systemd-reload-telegraf:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/telegraf.service.d/override.conf
    - watch_in:
      - service: telegraf

/etc/systemd/system/telegraf.service.d/override.conf:
{%- if 'vpngw' in role or 'nextgen-gateway' in role %}
  file.managed:
    - makedirs: True
    - contents: |
        [Service]
        # allow fetching metrics for wireguard
        CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
        AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
{% else %}
  file.absent
{% endif %}

/etc/telegraf/telegraf.conf:
  file.managed:
    - source: salt://telegraf/files/telegraf.conf
    - template: jinja
    - watch_in:
          service: telegraf

{% if salt["pillar.get"]("netbox:config_context:jitsi:asterisk:enabled", False) %}
/usr/local/bin/get_asterisk_calls.sh:
  file.managed:
    - contents: |
        #!/bin/bash
        asterisk -x "core show channels" | awk '/active call/ {print $1}'
    - mode: "0750"
    - user: root

/etc/sudoers.d/telegraf_asterisk:
  file.managed:
    - contents: |
        telegraf    ALL=(ALL:ALL) NOPASSWD:/usr/local/bin/get_asterisk_calls.sh

/etc/telegraf/telegraf.d/in-asterisk.conf:
  file.managed:
    - source: salt://telegraf/files/in_asterisk.conf
    - watch_in:
          service: telegraf
{% else %}
remove_asterisk_monitoring:
  file.absent:
    - names:
      - /usr/local/bin/get_asterisk_calls.sh
      - /etc/sudoers.d/telegraf_asterisk
      - /etc/telegraf/telegraf.d/in-asterisk.conf
{% endif %}

{% if salt["service.enabled"]("coturn") %}
/usr/local/bin/coturn_sessions:
  file.managed:
    - contents: |
        #!/bin/sh
        # Count turn-sessions
        netstat -tn | awk '$4 ~ /:443$/{print $5}' | cut -d: -f1 | uniq | wc -l
    - mode: "0755"

/etc/telegraf/telegraf.d/in-coturn_sessions.conf:
  file.managed:
    - source: salt://telegraf/files/in_coturn_sessions.conf
    - watch_in:
          service: telegraf
{% else %}
/usr/local/bin/coturn_sessions:
  file.absent:
    - watch_in:
          service: telegraf
/etc/telegraf/telegraf.d/in-coturn_sessions.conf:
  file.absent:
    - watch_in:
          service: telegraf
{% endif %}

/etc/telegraf/telegraf.d/in-dhcpd-pool-stats.conf:
{% if 'gateway' in role or 'nextgen-gateway' in role %}
  file.managed:
    - source: salt://telegraf/files/in_dhcpd-pool.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-dnsdist.conf:
{% if 'dnsdist' in tags %}
  file.managed:
    - source: salt://telegraf/files/in_dnsdist.conf
    - template: jinja
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-jicofo.conf:
{% if salt['pillar.get']('netbox:config_context:jitsi:jicofo:enabled', False) %}
  file.managed:
    - source: salt://telegraf/files/in_jicofo.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-jigasi.conf:
{% if salt['pillar.get']('netbox:config_context:jitsi:jigasi:enabled', False) %}
  file.managed:
    - source: salt://telegraf/files/in_jigasi.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-jvb-stats.conf:
{% if salt['pillar.get']('netbox:config_context:jitsi:videobridge:enabled', False) %}
  file.managed:
    - source: salt://telegraf/files/in_jitsi-videobridge.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-nginx.conf:
{% if 'webserver-external' == role or 'jitsi meet' == role %}
  file.managed:
    - source: salt://telegraf/files/in_nginx.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-powerdns_recursor.conf:
{% if salt["service.available"]("pdns-recursor") %}
  file.managed:
    - source: salt://telegraf/files/in_powerdns_recursor.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-gateway-modules.conf:
{% if 'gateway' in role or 'nextgen-gateway' in role or 'vpngw' in role %}
  file.managed:
    - source: salt://telegraf/files/in_gateway-modules.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/in-wireguard.conf:
{%- if 'vpngw' in role or 'nextgen-gateway' in role %}
  file.managed:
    - source: salt://telegraf/files/in_wireguard.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

/etc/telegraf/telegraf.d/out-influxdb.conf:
  file.managed:
    - source: salt://telegraf/files/out_influxdb.conf
    - template: jinja
    - require_in:
        - service: telegraf
    - watch_in:
        service: telegraf

/etc/telegraf/telegraf.d/in-nodes-online.conf:
{% if "yanic" in tags %}
  file.managed:
    - source: salt://telegraf/files/in_nodes-online.conf
{% else %}
  file.absent:
{% endif %}
    - watch_in:
          service: telegraf

{% endif %}{# if telegraf in tags #}
