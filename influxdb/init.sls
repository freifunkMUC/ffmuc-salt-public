#
# influxdb
#
{%- if 'influxdb_server' in salt['pillar.get']('netbox:tag_list', []) %}
influxdb-repo-key:
  cmd.run:
    - name: "curl https://repos.influxdata.com/influxdb.key | gpg --dearmor -o /usr/share/keyrings/influxdb-keyring.gpg"
    - creates: /usr/share/keyrings/influxdb-keyring.gpg

influxdb-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/influxdb-keyring.gpg] https://repos.influxdata.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }} stable
    - file: /etc/apt/sources.list.d/influxdb.list
    - clean_file: True
    - require:
      - cmd: influxdb-repo-key

influxdb-pkg:
  pkg.installed:
    - name: influxdb
    - require:
      - pkgrepo: influxdb-repo

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
