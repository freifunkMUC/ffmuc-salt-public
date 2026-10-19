{% if grains.os == 'Raspbian' %}
{#- no armhf in the graylog and elastic repos: fixed .debs, same IDs as pkg.latest below for the requisites #}
graylog-sidecar:
  pkg.installed:
    - sources:
      - graylog-sidecar: https://github.com/Graylog2/collector-sidecar/releases/download/1.5.6/graylog-sidecar_1.5.6-1_armv7.deb

filebeat:
  pkg.installed:
    - sources:
      - filebeat: https://apt.ffmuc.net/filebeat-oss-9.5.5-ffmuc1-armhf.deb

{% else %}{# if Raspbian #}

graylog-repo-key:
    cmd.run:
      - name: "wget -O - -o /dev/null https://packages.graylog2.org/repo/debian/keyring.gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/graylog-keyring.gpg.tmp && mv /usr/share/keyrings/graylog-keyring.gpg.tmp /usr/share/keyrings/graylog-keyring.gpg"
      {#- refetch while the keyring lacks the uid of 11/2025: the old one is bound by SHA1 only, which sqv on trixie rejects #}
      - unless: gpg --show-keys --with-colons /usr/share/keyrings/graylog-keyring.gpg 2>/dev/null | grep -q '^uid:.*Graylog, Inc\.'

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
    - name: "wget -O - -o /dev/null https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --batch --yes --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg.tmp && mv /usr/share/keyrings/elasticsearch-keyring.gpg.tmp /usr/share/keyrings/elasticsearch-keyring.gpg"
    {#- refetch while the uid self-signature predates 2023-09-05 (SHA1 only, rejected by sqv on trixie) #}
    - unless: gpg --show-keys --with-colons /usr/share/keyrings/elasticsearch-keyring.gpg 2>/dev/null | awk -F ':' '$1 == "uid" && $6 >= 1693907673' | grep -q .

/etc/apt/sources.list.d/elastic-7.x.list:
  file.absent

/etc/apt/sources.list.d/elastic-8.x.list:
  file.absent

filebeat-repo:
  pkgrepo.managed:
    - humanname: Elastic-Repo
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/oss-9.x/apt stable main
    - file: /etc/apt/sources.list.d/elastic-9.x.list
    - clean_file: True
    - require:
      - cmd: elasticsearch-repo-key

graylog-sidecar:
  pkg.latest

filebeat:
  pkg.latest

{% endif %}{# if Raspbian #}

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
    - mode: "0600"  # contains the server API token
    - show_changes: False
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
      - pkg: filebeat
      - file: graylog-sidecar-config
