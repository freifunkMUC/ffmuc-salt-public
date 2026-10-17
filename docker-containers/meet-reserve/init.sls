{#- Signer for signed viewers-only rooms (meet.ffmuc.net/reserve).
    Config in the Netbox config context "meet_reserve"; the matching public key
    is jitsi:signed_rooms:public_keys on the prosody hosts. -#}
{%- set cfg = salt["pillar.get"]("netbox:config_context:meet_reserve", {}) %}
{%- if cfg.get("enabled", False) %}

/srv/docker/meet-reserve/src:
  file.recurse:
    - source: salt://docker-containers/meet-reserve/src
    - makedirs: True
    - clean: True

/srv/docker/meet-reserve/.env:
  file.managed:
    - mode: "0600"
    - contents: |
        RESERVE_PRIVATE_KEY={{ cfg["private_key"] }}
        RESERVE_KEY_ID={{ cfg.get("key_id", 1) }}
        RESERVE_POW_DIFFICULTY={{ cfg.get("pow_difficulty", 18) }}
        RESERVE_DURATIONS={{ cfg.get("durations", "24h,72h,168h") }}
        RESERVE_DEFAULT_DURATION={{ cfg.get("default_duration", "72h") }}
        RESERVE_MAX_EXTENSION={{ cfg.get("max_extension", "720h") }}
        RESERVE_PUBLIC_URL={{ cfg.get("public_url", "https://meet.ffmuc.net") }}
        RESERVE_LISTEN=:8095
        RESERVE_METRICS_LISTEN=:9195
    - require:
      - file: /srv/docker/meet-reserve/src

/srv/docker/meet-reserve/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/meet-reserve/docker-compose.yml.j2
    - template: jinja
    - context:
        port: {{ cfg.get("port", 8095) }}
        metrics_port: {{ cfg.get("metrics_port", 9195) }}
    - require:
      - file: /srv/docker/meet-reserve/src

start-meet-reserve:
  cmd.run:
    - name: docker compose up -d --build --remove-orphans
    - cwd: /srv/docker/meet-reserve
    - onchanges:
      - file: /srv/docker/meet-reserve/src
      - file: /srv/docker/meet-reserve/.env
      - file: /srv/docker/meet-reserve/docker-compose.yml

{%- else %}

stop-meet-reserve:
  cmd.run:
    - name: docker compose down
    - cwd: /srv/docker/meet-reserve
    - onlyif: test -f /srv/docker/meet-reserve/docker-compose.yml

/srv/docker/meet-reserve:
  file.absent:
    - require:
      - cmd: stop-meet-reserve
{%- endif %}
