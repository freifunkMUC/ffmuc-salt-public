{#- Signer for reserved viewers-only rooms (meet.ffmuc.net/reserve).
    Config in the Netbox config context "meet_reserve"; the matching public key
    is jitsi:signed_rooms:public_keys on the prosody hosts.
    All signers share the keys and replicate the room records with each other
    over Nebula (port 8096, see nebula/files/config.yml.jinja):
      signers: [docker04.in.ffmuc.net, ...]   minion ids, peers are <id with .ov.>:8096
      sync_key: base64 32 bytes, different from pow_key -#}
{%- set cfg = salt["pillar.get"]("netbox:config_context:meet_reserve", {}) %}
{%- if cfg.get("enabled", False) %}
{%- set peers = [] %}
{%- for signer in cfg.get("signers", []) if signer != grains["id"] %}
{%-   do peers.append("http://" ~ signer | replace(".in.", ".ov.") ~ ":8096") %}
{%- endfor %}
{%- set sync_ip = salt["grains.get"]("ip4_interfaces:" ~ salt["pillar.get"]("nebula:interface", "nebula0") ~ ":0", "") %}

/srv/docker/meet-reserve/src:
  file.recurse:
    - source: salt://docker-containers/meet-reserve/src
    - makedirs: True
    - clean: True

# room records; distroless "nonroot" is uid 65532
/srv/docker/meet-reserve/data:
  file.directory:
    - user: 65532
    - group: 65532
    - mode: "0700"
    - makedirs: True

/srv/docker/meet-reserve/.env:
  file.managed:
    - mode: "0600"
    - contents: |
        RESERVE_PRIVATE_KEY={{ cfg["private_key"] }}
        RESERVE_POW_KEY={{ cfg["pow_key"] }}
        RESERVE_SYNC_KEY={{ cfg["sync_key"] }}
        RESERVE_PEERS={{ peers | join(",") }}
        RESERVE_KEY_ID={{ cfg.get("key_id", 1) }}
        RESERVE_POW_DIFFICULTY={{ cfg.get("pow_difficulty", 18) }}
        RESERVE_DURATIONS={{ cfg.get("durations", "72h,168h,720h,2160h,8760h") }}
        RESERVE_DEFAULT_DURATION={{ cfg.get("default_duration", "72h") }}
        RESERVE_MAX_AHEAD={{ cfg.get("max_ahead", "8760h") }}
        RESERVE_LINK_TTL={{ cfg.get("link_ttl", "12h") }}
        RESERVE_LEGACY_MAX_EXTENSION={{ cfg.get("max_extension", "720h") }}
        RESERVE_PUBLIC_URL={{ cfg.get("public_url", "https://meet.ffmuc.net") }}
        RESERVE_DATA_DIR=/data
        RESERVE_LISTEN=:8095
        RESERVE_SYNC_LISTEN=:8096
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
        sync_ip: "{{ sync_ip if peers else "" }}"
    - require:
      - file: /srv/docker/meet-reserve/src

start-meet-reserve:
  cmd.run:
    - name: docker compose up -d --build --remove-orphans
    - cwd: /srv/docker/meet-reserve
    - require:
      - file: /srv/docker/meet-reserve/data
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
