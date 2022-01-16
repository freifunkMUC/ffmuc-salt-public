#
# Setup docker.io
#
{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:device_role:name')) %}

{% if 'docker' in role or 'mailserver' in role or 'roadwarrior' in role %}
docker-repo:
  pkgrepo.managed:
    - comments: "# Docker.io"
    - human_name: Docker.io repository
    - name: "deb [arch={{ grains.osarch }}] https://download.docker.com/linux/{{ grains.lsb_distrib_id | lower }}  {{ grains.oscodename }} stable"
    - dist: {{ grains.oscodename }}
    - file: /etc/apt/sources.list.d/docker.list
    - key_url: https://download.docker.com/linux/{{ grains.lsb_distrib_id | lower }}/gpg

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
    - source: https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64
    - source_hash: f15a7cd54a85f760a8ece92da63fb85b93036c72ead8056391b8a3fe9dc73134
    - mode: "0755"

{#
# Install docker-compose via pip *shrug*
python-pip:
  pkg.installed

docker-compose:
  pip.installed:
    - require:
      - pkg: python-pip
#}
{% endif  %}
