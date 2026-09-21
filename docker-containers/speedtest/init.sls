
{% if salt["pillar.get"]("netbox:config_context:docker:speedtest:enabled", False) %}

/srv/docker/speedtest/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/speedtest/docker-compose.yml.j2
    - makedirs: True
    - template: jinja

/srv/docker/speedtest/servers.json:
  file.managed:
    - source: salt://docker-containers/speedtest/servers.json
    - makedirs: True
    - template: jinja

start-speedtest:
  cmd.run:
    - name: docker-compose down && docker-compose up -d
    - cwd: /srv/docker/speedtest
    - require:
        - file: /srv/docker/speedtest/docker-compose.yml
        - file: /srv/docker/speedtest/servers.json
    - onchanges:
        - file: /srv/docker/speedtest/docker-compose.yml
        - file: /srv/docker/speedtest/servers.json
{% endif %}