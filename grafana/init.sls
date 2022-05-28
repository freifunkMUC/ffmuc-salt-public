#
# grafana
#
{% if 'grafana_server' in salt['pillar.get']('netbox:tag_list', []) %}

grafana-repo-key:
  cmd.run:
    - name: "curl https://packages.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana-keyring.gpg"
    - creates: /usr/share/keyrings/grafana-keyring.gpg

grafana:
# add Grafana Repo
  pkgrepo.managed:
    - humanname: Grafana Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/grafana-keyring.gpg] https://packages.grafana.com/oss/deb stable main
    - file: /etc/apt/sources.list.d/grafana.list
    - clean_file: True
    - require:
      - cmd: grafana-repo-key
# install grafana
  pkg.installed:
    - name: grafana
    - require:
      - pkgrepo: grafana
  service.running:
    - name: grafana-server
    - enable: True
    - require:
      - pkg: grafana
      - file: /etc/grafana/grafana.ini
      - file: /etc/grafana/ldap.toml
      - user: grafana
    - watch:
      - file: /etc/grafana/grafana.ini
      - file: /etc/grafana/ldap.toml
# add user 'grafana' to group 'ssl-cert' to access ssl-key file
  user.present:
    - name: grafana
    - system: True
    - groups:
      - ssl-cert
    - require:
      - pkg: grafana

# copy custom config
/etc/grafana/grafana.ini:
  file.managed:
    - source: salt://grafana/grafana.ini.tmpl
    - template: jinja
    - require:
      - pkg: grafana

# copy LDAP config
/etc/grafana/ldap.toml:
  file.managed:
    - source: salt://grafana/ldap.toml.tmpl
    - template: jinja
    - require:
      - pkg: grafana

#
# Plugins

# Grafana-Piechart-Panel
grafana-piechart:
  cmd.run:
    - name: grafana-cli plugins install grafana-piechart-panel
    - creates: /var/lib/grafana/plugins/grafana-piechart-panel
    - watch_in:
      - service: grafana
{% endif %}
