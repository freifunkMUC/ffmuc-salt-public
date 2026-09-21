#
# diun - notifies about updated container images
#
{% if salt["pillar.get"]("netbox:config_context:docker:diun:enabled", True) %}

/srv/docker/diun:
  file.directory:
    - user: root
    - group: root
    - mode: "0750"
    - makedirs: True

/srv/docker/diun/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/diun/docker-compose.yml.j2
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /srv/docker/diun

{#- 0600: this file carries the Slack webhook URL, which is a credential. #}
/srv/docker/diun/diun.yml:
  file.managed:
    - source: salt://docker-containers/diun/diun.yml.j2
    - template: jinja
    - user: root
    - group: root
    - mode: "0600"
    - require:
      - file: /srv/docker/diun

/srv/docker/diun/data:
  file.directory:
    - user: root
    - group: root
    - mode: "0750"
    - require:
      - file: /srv/docker/diun

diun-compose:
  cmd.run:
    - name: docker compose pull && docker compose up -d --remove-orphans
    - cwd: /srv/docker/diun
    - require:
      - file: /srv/docker/diun/docker-compose.yml
      - file: /srv/docker/diun/diun.yml
      - file: /srv/docker/diun/data
    - onchanges:
      - file: /srv/docker/diun/docker-compose.yml
      - file: /srv/docker/diun/diun.yml
{% endif %}
