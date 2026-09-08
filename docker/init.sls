#
# Setup docker.io
#
{#- Default to '' rather than to the same lookup again: an unset role made
    this None, and `'docker' in None` aborts the render with a TypeError. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}

{% if 'docker' in role or 'mailserver' in role or 'roadwarrior' in role %}
docker-repo-key:
  cmd.run:
    - name: "curl -fsSL https://download.docker.com/linux/{{ grains.lsb_distrib_id | lower }}/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-keyring.gpg.tmp && mv /usr/share/keyrings/docker-keyring.gpg.tmp /usr/share/keyrings/docker-keyring.gpg"
    - creates: /usr/share/keyrings/docker-keyring.gpg

docker-repo:
  pkgrepo.managed:
    - comments: "# Docker.io"
    - human_name: Docker.io repository
    - name: "deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/docker-keyring.gpg] https://download.docker.com/linux/{{ grains.lsb_distrib_id | lower }}  {{ grains.oscodename }} stable"
    - dist: {{ grains.oscodename }}
    - file: /etc/apt/sources.list.d/docker.list
    - clean_file: True
    - require:
      - cmd: docker-repo-key

docker-pkgs:
  pkg.installed:
    - pkgs:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-compose-plugin
    - require:
      - pkgrepo: docker-repo

{# limit log-file-size #}
/etc/docker/daemon.json:
  file.managed:
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - pkg: docker-pkgs
    - contents: |
        {
          "log-driver": "json-file",
          "log-opts": {
            "max-size": "10m",
            "max-file": "3"
          },
          "default-address-pools": [
            {
              "base": "172.17.0.0/12",
              "size": 24
            },
            {
              "base": "192.168.0.0/16",
              "size": 24
            }
          ]
        }

{#- Nothing used to restart dockerd, so daemon.json only ever took effect
    after a manual restart or a reboot - meaning the log size limits above
    were not actually in force on long-running hosts. Note that a change to
    daemon.json now bounces the containers on that host; the file is a static
    literal, so this only fires when someone edits it here. #}
docker-service:
  service.running:
    - name: docker
    - enable: True
    - require:
      - pkg: docker-pkgs
    - watch:
      - file: /etc/docker/daemon.json

{#- Compose v1 is gone; everything uses the `docker compose` plugin. #}
/usr/local/bin/docker-compose:
  file.absent
{% endif  %}
