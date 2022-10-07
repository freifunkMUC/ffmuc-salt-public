
{% if grains.osfullname in 'Raspbian' %}
graylog-sidecar-pkg:
  pkg.installed:
    - sources:
      - graylog-sidecar: http://apt.ffmuc.net/graylog-sidecar_1.1.0-0.SNAPSHOT_armhf.deb
      - filebeat: https://apt.ffmuc.net/filebeat-oss-8.0.0-SNAPSHOT-armhf.deb

{% else %}{# if grains.osfullname in 'Raspbian' #}

graylog-repo-key:
  file.managed:
    - name: /usr/share/keyrings/graylog-keyring.gpg
    - source: salt://graylog-sidecar/graylog-keyring.gpg

graylog-repo:
    pkgrepo.managed:
    - humanname: Graylog-Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/graylog-keyring.gpg] https://packages.graylog2.org/repo/debian/ sidecar-stable 1.2
    - file: /etc/apt/sources.list.d/graylog-sidecar.list
    - clean_file: True
    - require:
      - cmd: graylog-repo-key

elasticsearch-repo-key:
  cmd.run:
    - name: "curl https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg"
    - creates: /usr/share/keyrings/elasticsearch-keyring.gpg

filebeat-repo:
  pkgrepo.managed:
    - humanname: Elastic-Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/oss-7.x/apt stable main
    - file: /etc/apt/sources.list.d/elastic-7.x.list
    - clean_file: True
    - require:
      - cmd: elasticsearch-repo-key

{% endif %}

graylog-sidecar:
  pkg.latest

filebeat:
  pkg.latest

{% if not salt['file.file_exists']('/etc/systemd/system/graylog-sidecar.service') %}
graylog-sidecar-install-service:
  cmd.run:
    - name: "graylog-sidecar -service install"
    - onchanges:
      - pkg: graylog-sidecar
{% endif %}

graylog-sidecar-config:
  file.managed:
    - name: /etc/graylog/sidecar/sidecar.yml
    - source: salt://graylog-sidecar/sidecar.yml
    - template: jinja
    - require:
      - pkg: graylog-sidecar

graylog-sidecar-service:
  service.running:
    - name: graylog-sidecar
    - enable: true
    - require:
      - pkg: graylog-sidecar
      - file: graylog-sidecar-config
    - watch:
      - pkg: graylog-sidecar
      - file: graylog-sidecar-config
