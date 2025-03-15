
{% if grains.osfullname in 'Raspbian' %}
graylog-sidecar-pkg:
  pkg.installed:
    - sources:
      - graylog-sidecar: https://github.com/Graylog2/collector-sidecar/releases/download/1.2.0/graylog-sidecar_1.2.0-1_armv7.deb
      - filebeat: https://apt.ffmuc.net/filebeat-oss-8.0.0-SNAPSHOT-armhf.deb

{% else %}{# if grains.osfullname in 'Raspbian' #}

graylog-repo-key:
    cmd.run:
      - name: "wget -O - -o /dev/null https://packages.graylog2.org/repo/debian/keyring.gpg | gpg --dearmor -o /usr/share/keyrings/graylog-keyring.gpg"
      - creates: /usr/share/keyrings/graylog-keyring.gpg

graylog-repo:
    pkgrepo.managed:
    - humanname: Graylog-Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/graylog-keyring.gpg] https://packages.graylog2.org/repo/debian/ sidecar-stable 1.5
    - file: /etc/apt/sources.list.d/graylog-sidecar.list
    - clean_file: True
    - require:
      - cmd: graylog-repo-key

elasticsearch-repo-key:
  cmd.run:
    - name: "wget -O - -o /dev/null https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg"
    - creates: /usr/share/keyrings/elasticsearch-keyring.gpg

/etc/apt/sources.list.d/elastic-7.x.list:
  file.absent

filebeat-repo:
  pkgrepo.managed:
    - humanname: Elastic-Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/oss-8.x/apt stable main
    - file: /etc/apt/sources.list.d/elastic-8.x.list
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
