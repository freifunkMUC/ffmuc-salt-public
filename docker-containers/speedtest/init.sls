#
# speedtest - LibreSpeed frontend plus backend
#
{% if salt["pillar.get"]("netbox:config_context:docker:speedtest:enabled", False) %}

/srv/docker/speedtest:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True

/srv/docker/speedtest/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/speedtest/docker-compose.yml.j2
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /srv/docker/speedtest

{#- No template: this is a static server list with no Jinja in it, and
    running it through the renderer would only risk tripping over a literal
    brace in a future entry. #}
/srv/docker/speedtest/servers.json:
  file.managed:
    - source: salt://docker-containers/speedtest/servers.json
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /srv/docker/speedtest

speedtest-compose:
  cmd.run:
    - name: docker compose pull && docker compose up -d --remove-orphans
    - cwd: /srv/docker/speedtest
    - require:
      - file: /srv/docker/speedtest/docker-compose.yml
      - file: /srv/docker/speedtest/servers.json
    - onchanges:
      - file: /srv/docker/speedtest/docker-compose.yml
      - file: /srv/docker/speedtest/servers.json
{% endif %}
