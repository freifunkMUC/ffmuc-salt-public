
{% if salt["pillar.get"]("netbox:config_context:docker:diun:enabled", True) %}

/srv/docker/diun/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/diun/docker-compose.yml
    - makedirs: True
    - template: jinja

/srv/docker/diun/diun.yml:
  file.managed:
    - source: salt://docker-containers/diun/diun.yml
    - makedirs: True
    - template: jinja

/srv/docker/diun/data:
  file.directory

start-diun:
  cmd.wait:
    - name: docker-compose up -d
    - cwd: /srv/docker/diun
    - require:
        - file: /srv/docker/diun/docker-compose.yml
        - file: /srv/docker/diun/diun.yml
        - file: /srv/docker/diun/data
    - watch:
        - file: /srv/docker/diun/docker-compose.yml
        - file: /srv/docker/diun/diun.yml
{% endif %}