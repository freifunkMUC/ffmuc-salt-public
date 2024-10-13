#
# influxdb
#
{%- if 'influxdb_server' in salt['pillar.get']('netbox:tag_list', []) %}
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

influxdb-pkg:
  pkg.installed:
    - name: influxdb
    - require:
      - pkgrepo: influx-db-repo

influxdb:
  service.running:
    - name: influxdb
    - enable: True
    - require:
      - pkg: influxdb-pkg
      - file: /etc/influxdb/influxdb.conf
    - watch:
      - file: /etc/influxdb/influxdb.conf

influxdb-user:
  user.present:
    - name: influxdb
    - system: True
    - groups:
      - ssl-cert
    - require:
      - pkg: influxdb-pkg

/etc/influxdb/influxdb.conf:
  file.managed:
    - source: salt://influxdb/influxdb.conf.tmpl
    - template: jinja
    - require:
      - pkg: influxdb-pkg

# avoid influxdb
/etc/rsyslog.d/influxd.conf:
  file.managed:
    - contents: |
        # Managed by Salt
        # avoid influxdb logs to fill syslog AND daemon.log
        :programname,isequal,"influxd"         /var/log/influxd.log
        & stop

/etc/logrotate.d/influxd.conf:
  file.managed:
    - source: salt://influxdb/logrotate.conf

{% endif %}
