{#- Self-hosted LibreTranslate for live translated subtitles in Jitsi (jigasi on call01
    sends the Vosk transcripts here over nebula-meet). Config in the Netbox config
    context "libretranslate"; jigasi points at it via jitsi:transcription:translation. -#}
{%- set cfg = salt["pillar.get"]("netbox:config_context:libretranslate", {}) %}
{%- if cfg.get("enabled", False) %}

/srv/docker/libretranslate:
  file.directory:
    - makedirs: True

/srv/docker/libretranslate/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/libretranslate/docker-compose.yml.j2
    - template: jinja
    - context:
        image: {{ cfg.get("image", "libretranslate/libretranslate:v1.9.6") }}
        port: {{ cfg.get("port", 5010) }}
        languages: {{ cfg.get("languages", "de,en,ar,bg,el,es,fa,fr,hu,it,pl,ro,ru,sq,tr,uk") }}
        threads: {{ cfg.get("threads", 4) }}
        mem_limit: {{ cfg.get("mem_limit", "8g") }}
    - require:
      - file: /srv/docker/libretranslate

start-libretranslate:
  cmd.run:
    - name: docker compose up -d --remove-orphans
    - cwd: /srv/docker/libretranslate
    - onchanges:
      - file: /srv/docker/libretranslate/docker-compose.yml

{%- else %}

stop-libretranslate:
  cmd.run:
    - name: docker compose down
    - cwd: /srv/docker/libretranslate
    - onlyif: test -f /srv/docker/libretranslate/docker-compose.yml

/srv/docker/libretranslate:
  file.absent:
    - require:
      - cmd: stop-libretranslate
{%- endif %}
