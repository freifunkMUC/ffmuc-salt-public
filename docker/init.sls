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
    - source: https://github.com/docker/compose/releases/download/v2.2.2/docker-compose-linux-x86_64
    - source_hash: 92551cd3d22b41536ce8345fe06795ad0d08cb3c17b693ecbfe41176e501bfd4
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
