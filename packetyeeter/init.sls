{# Standalone state: this formula is intentionally not referenced by top.sls.
   It only runs when explicitly targeted via: salt '<target>' state.apply packetyeeter

   Enablement is controlled purely by Netbox tags (netbox:tag_list), NOT config_context:
     - packetyeeter-collector -> installs/runs the collector (enforcer) on this host
     - packetyeeter-analyzer  -> installs/runs the analyzer (decision service) on this host

   The collector and analyzer share one default release version (see
   default_version below), so tagging alone is enough for both: the collector
   installs the matching .deb, and the analyzer pulls the matching
   ghcr.io/awlx/packetyeeter-analyzer:v<version> image (not :latest, for
   reproducible deploys). Override netbox:config_context:packetyeeter:collector:version
   (or :deb_url) and/or :analyzer:version (or :image) to pin a
   different/newer release once available.
   netbox:config_context:packetyeeter is otherwise OPTIONAL and only used to
   override specific defaults (e.g. interface, analyzer_addr, image). #}

{% set tags = salt['config.get']('netbox:tag_list', []) %}
{% set collector_enabled = 'packetyeeter-collector' in tags %}
{% set analyzer_enabled = 'packetyeeter-analyzer' in tags %}

{% if collector_enabled or analyzer_enabled %}

{% set overrides = salt['config.get']('netbox:config_context:packetyeeter', {}) %}
{% set collector_overrides = overrides.get('collector', {}) %}
{% set analyzer_overrides = overrides.get('analyzer', {}) %}
{% set own_location = salt['config.get']('netbox:site:name', '') %}

{# Auto-discover a same-site analyzer via the mine, so collectors don't need
   analyzer_addr set explicitly. Falls back to localhost if none is found.
   NOTE: uses a Jinja namespace() object, not a plain {% set %}, because
   {% set %} assignments inside a {% for %} loop are scoped to that loop
   iteration and do NOT persist outside it (classic Jinja2 gotcha) - a plain
   variable here would silently never propagate the discovered address. #}
{% set ns = namespace(analyzer_addr='') %}
{% if collector_enabled %}
  {% set analyzer_ids = salt['mine.get']('netbox:tag_list:packetyeeter-analyzer', 'minion_id', tgt_type='pillar') %}
  {% for node in analyzer_ids %}
    {% if not ns.analyzer_addr %}
      {% set node_location = salt['mine.get'](node, 'minion_location', tgt_type='glob') %}
      {% if node_location and node_location.get(node) == own_location %}
        {% set node_addr = salt['mine.get'](node, 'minion_address', tgt_type='glob') %}
        {% if node_addr and node_addr.get(node) %}
          {% set ns.analyzer_addr = node_addr[node].split('/')[0] ~ ':9090' %}
        {% endif %}
      {% endif %}
    {% endif %}
  {% endfor %}
{% endif %}

{# Reuse the GeoLite2-ASN.mmdb the haproxy formula already downloads to
   /etc/haproxy/geoip on webfrontends, instead of fetching/storing a second
   copy for the collector. Hosts without haproxy (e.g. the analyzer's docker
   host) fall back to a standalone path. #}
{% set haproxy_geoip_asn = '/etc/haproxy/geoip/GeoLite2-ASN.mmdb' %}
{% set default_geoip_asn = haproxy_geoip_asn if salt['file.file_exists'](haproxy_geoip_asn) else '/var/lib/GeoIP/GeoLite2-ASN.mmdb' %}

{# Auto-detect the external/uplink interface the same way bird2 and iptables
   do (netbox:config_context:network:uplink_vlan:interface, e.g. "vlan101"),
   instead of assuming "eth0" which doesn't exist on these hosts. Falls back
   to eth0 only if that config_context key is absent.
   NOTE: use config.get, not pillar.get - this sub-dict is also wrapped as a
   MaskedDict (same issue as netbox:config_context:wireguard etc.), so
   pillar.get returns '**********' here too. #}
{% set uplink_iface = salt['config.get']('netbox:config_context:network:uplink_vlan:interface', '') %}
{% set default_iface = uplink_iface if uplink_iface else 'eth0' %}

{# Default allowlist: this site's own Netbox-registered prefixes
   (netbox:site:prefixes, already in pillar - no extra API call needed).
   Excludes our own IP ranges from the collector's kernel-space detections
   AND the SPOE path (checkAllowlist runs before any SPOE signal is emitted
   to the analyzer, so this single collector-side setting also keeps our own
   traffic out of the analyzer's reputation/detection tracking entirely). #}
{% set site_prefix_objs = salt['config.get']('netbox:site:prefixes', []) %}
{% set own_site_prefixes = [] %}
{% for p in site_prefix_objs %}
  {% if p.get('prefix') %}
    {% do own_site_prefixes.append(p['prefix']) %}
  {% endif %}
{% endfor %}
{% set default_allowlist = own_site_prefixes | join(',') %}

{# Shared default release version for both daemons - bump this when a new
   packetyeeter version is published, so the collector .deb and the analyzer
   Docker image stay in lockstep by default. #}
{% set default_version = '0.1.7' %}

{# The collector runs natively (systemd) since it needs to load eBPF/XDP/TC
   programs against a host interface - this isn't practical to containerize.
   Installed from the project's official .deb package (nfpm), which ships its
   own systemd unit, capabilities, and /etc/default/packetyeeter-collector
   template - so we no longer manage a custom binary or .service file here.
   Defaults to default_version; override collector:version (or
   collector:deb_url) via config_context to pin a different/newer release
   independently of the analyzer. #}
{% set collector_defaults = {
  'version': default_version,
  'deb_url': '',
  'interface': default_iface,
  'analyzer_addr': ns.analyzer_addr if ns.analyzer_addr else '127.0.0.1:9090',
  'metrics_addr': ':2112',
  'haproxy_port': 8765,
  'spoe_port': 9876,
  'socket_path': '/var/run/packetyeeter-collector.sock',
  'geoip_asn': default_geoip_asn,
  'block_duration': '5m',
  'allowlist': default_allowlist,
  'dry_run': True,
} %}
{% set collector = {} %}
{% do collector.update(collector_defaults) %}
{% do collector.update(collector_overrides) %}
{% if not collector['deb_url'] and collector['version'] %}
  {% do collector.update({'deb_url': 'https://github.com/awlx/packetyeeter/releases/download/v' ~ collector['version'] ~ '/packetyeeter-collector_' ~ collector['version'] ~ '_amd64.deb'}) %}
{% endif %}

{# The analyzer runs dockerized on the docker host, using the official image.
   Defaults to default_version's matching tag (ghcr.io/awlx/packetyeeter-
   analyzer:v<version>), NOT :latest, for reproducible deploys - CI publishes
   an image tagged with the release tag itself for every vX.Y.Z push.
   collector:version and analyzer:version are independent config keys (no
   automatic linkage beyond sharing the same default_version) - set
   analyzer:version (or analyzer:image directly) to pin/override just the
   analyzer. #}
{% set geoip_container_path = '/data/geoip/GeoLite2-ASN.mmdb' %}
{# If the haproxy-managed copy isn't present on this host (e.g. a docker host
   with no haproxy formula applied), download our own copy into a
   docker-managed folder instead of running the analyzer without ASN
   enrichment. Same mirror the haproxy formula already uses. #}
{% set docker_geoip_asn = '/srv/docker/packetyeeter-analyzer/geoip/GeoLite2-ASN.mmdb' %}
{% set haproxy_geoip_exists = salt['file.file_exists'](haproxy_geoip_asn) %}
{% set analyzer_geoip_host_path = haproxy_geoip_asn if haproxy_geoip_exists else docker_geoip_asn %}

{# GeoIP country enrichment (powers the analyzer's "Threats by Country"
   panel, v0.1.6+). A GeoLite2-City.mmdb also contains country data, so we
   reuse the haproxy formula's existing City DB when present (webfrontends)
   instead of downloading a second file; docker-only hosts (no haproxy) get
   their own GeoLite2-Country.mmdb download. Always enabled - no gate flag,
   since it's harmless/optional on the analyzer side (gracefully degrades to
   "unknown" if the file is ever missing). #}
{% set haproxy_geoip_city = '/etc/haproxy/geoip/GeoLite2-City.mmdb' %}
{% set docker_geoip_country = '/srv/docker/packetyeeter-analyzer/geoip/GeoLite2-Country.mmdb' %}
{% set haproxy_geoip_city_exists = salt['file.file_exists'](haproxy_geoip_city) %}
{% set analyzer_geoip_country_host_path = haproxy_geoip_city if haproxy_geoip_city_exists else docker_geoip_country %}
{% set geoip_country_container_path = '/data/geoip/GeoLite2-Country.mmdb' %}
{% set analyzer_defaults = {
  'version': default_version,
  'image': '',
  'listen_port': 9090,
  'metrics_port': 9091,
  'inspect_port': 9092,
  'reputation_threshold': 75.0,
  'ai_confidence_threshold': 0.8,
  'dry_run': True,
  'verbose': False,
  'geoip_enabled': True,
  'geoip_host_path': analyzer_geoip_host_path,
  'geoip_container_path': geoip_container_path,
  'geoip_country_host_path': analyzer_geoip_country_host_path,
  'geoip_country_container_path': geoip_country_container_path,
} %}
{% set analyzer = {} %}
{% do analyzer.update(analyzer_defaults) %}
{% do analyzer.update(analyzer_overrides) %}
{% if not analyzer['image'] and analyzer['version'] %}
  {% do analyzer.update({'image': 'ghcr.io/awlx/packetyeeter-analyzer:v' ~ analyzer['version']}) %}
{% endif %}

packetyeeter-runtime-pkgs:
  pkg.installed:
    - pkgs:
      - ca-certificates

{% if collector_enabled %}
{% if collector['deb_url'] %}
packetyeeter-collector-pkg:
  pkg.installed:
    - sources:
      - packetyeeter-collector: {{ collector['deb_url'] }}
    - require:
      - pkg: packetyeeter-runtime-pkgs

/etc/default/packetyeeter-collector:
  file.managed:
    - source: salt://packetyeeter/packetyeeter-collector.default.jinja
    - template: jinja
    - mode: "0644"
    - context:
      collector: {{ collector | json }}
    - require:
      - pkg: packetyeeter-collector-pkg

{# The officially packaged unit (v0.1.0) uses bash-only ${VAR:-default}
   expansion in ExecStart, which native systemd does not support (fails even
   when the variable IS set - confirmed via journalctl INVALIDARGUMENT).
   Override just ExecStart with a corrected, plain-${VAR} version. #}
/etc/systemd/system/packetyeeter-collector.service.d:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True
    - require:
      - pkg: packetyeeter-collector-pkg

/etc/systemd/system/packetyeeter-collector.service.d/override.conf:
  file.managed:
    - source: salt://packetyeeter/packetyeeter-collector-override.conf
    - mode: "0644"
    - require:
      - file: /etc/systemd/system/packetyeeter-collector.service.d

packetyeeter-collector-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/packetyeeter-collector.service.d/override.conf

packetyeeter-collector-service:
  service.running:
    - name: packetyeeter-collector
    - enable: True
    - require:
      - file: /etc/default/packetyeeter-collector
      - file: /etc/systemd/system/packetyeeter-collector.service.d/override.conf
      - cmd: packetyeeter-collector-daemon-reload
      - pkg: packetyeeter-collector-pkg
    - watch:
      - file: /etc/default/packetyeeter-collector
      - file: /etc/systemd/system/packetyeeter-collector.service.d/override.conf
{% else %}
packetyeeter-collector-version-missing:
  test.fail_without_changes:
    - name: "packetyeeter collector enabled, but netbox:config_context:packetyeeter:collector:version (or :deb_url) is not set - pin it to a real published release"
{% endif %}
{% endif %}

{% if analyzer_enabled %}
/srv/docker/packetyeeter-analyzer:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True

/srv/docker/packetyeeter-analyzer/data:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - file: /srv/docker/packetyeeter-analyzer

{# Persistent storage for the analyzer's ML state (feedback loop allowlist,
   learned patterns, trained model) and recorded traffic sessions used for
   ML training - both previously written inside the container only and lost
   on every recreate since nothing mounted these paths to host storage. #}
/srv/docker/packetyeeter-analyzer/ml-data:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - file: /srv/docker/packetyeeter-analyzer

/srv/docker/packetyeeter-analyzer/ml-data/sessions:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - file: /srv/docker/packetyeeter-analyzer/ml-data

{% if not haproxy_geoip_exists or not haproxy_geoip_city_exists %}
/srv/docker/packetyeeter-analyzer/geoip:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - require:
      - file: /srv/docker/packetyeeter-analyzer

{% if not haproxy_geoip_exists %}
packetyeeter-analyzer-geoip-asn:
  cmd.run:
    - name: wget -qO {{ docker_geoip_asn }} https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb
    - creates: {{ docker_geoip_asn }}
    - require:
      - file: /srv/docker/packetyeeter-analyzer/geoip
{% endif %}

{% if not haproxy_geoip_city_exists %}
packetyeeter-analyzer-geoip-country:
  cmd.run:
    - name: wget -qO {{ docker_geoip_country }} https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb
    - creates: {{ docker_geoip_country }}
    - require:
      - file: /srv/docker/packetyeeter-analyzer/geoip
{% endif %}
{% endif %}

/srv/docker/packetyeeter-analyzer/docker-compose.yml:
  file.managed:
    - source: salt://packetyeeter/packetyeeter-analyzer-compose.yml.j2
    - template: jinja
    - mode: "0644"
    - context:
      analyzer: {{ analyzer | json }}
    - require:
      - file: /srv/docker/packetyeeter-analyzer

packetyeeter-analyzer-compose:
  cmd.run:
    - name: docker compose pull && docker compose up -d
    - cwd: /srv/docker/packetyeeter-analyzer
    - require:
      - file: /srv/docker/packetyeeter-analyzer/docker-compose.yml
      - file: /srv/docker/packetyeeter-analyzer/data
      - file: /srv/docker/packetyeeter-analyzer/ml-data
      - file: /srv/docker/packetyeeter-analyzer/ml-data/sessions
{% if not haproxy_geoip_exists %}
      - cmd: packetyeeter-analyzer-geoip-asn
{% endif %}
{% if not haproxy_geoip_city_exists %}
      - cmd: packetyeeter-analyzer-geoip-country
{% endif %}
    - onchanges:
      - file: /srv/docker/packetyeeter-analyzer/docker-compose.yml
{% endif %}

{% else %}
packetyeeter-disabled:
  test.nop:
    - name: "packetyeeter: no packetyeeter-collector/packetyeeter-analyzer tag in netbox:tag_list on this host"
{% endif %}
