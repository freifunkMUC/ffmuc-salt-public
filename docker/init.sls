#
# Setup docker.io
#
{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:device_role:name')) %}

{% if 'docker' in role or 'mailserver' in role or 'roadwarrior' in role %}
docker-repo-key:
  cmd.run:
    - name: "curl https://download.docker.com/linux/{{ grains.lsb_distrib_id | lower }}/gpg | gpg --dearmor -o /usr/share/keyrings/docker-keyring.gpg"
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
    - require:
      - pkgrepo: docker-repo

{# limit log-file-size #}
/etc/docker/daemon.json:
  file.managed:
    - contents: |
        {
          "log-driver": "json-file",
          "log-opts": {
            "max-size": "10m",
            "max-file": "3"
          }
        }

/usr/local/bin/docker-compose:
  file.managed:
    - source: https://github.com/docker/compose/releases/download/v2.5.0/docker-compose-linux-x86_64
    - source_hash: 6296d17268c77a7159f57f04ed26dd2989f909c58cca4d44d1865f28bd27dd67
    - mode: "0755"
{% endif  %}
