##
# Prosody for jitsi (WIP)
##
{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.prosody.enabled %}

prosody-repo-key:
  cmd.run:
    - name: "curl -fsSL https://prosody.im/files/prosody-debian-packages.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/prosody-keyring.gpg.tmp && mv /usr/share/keyrings/prosody-keyring.gpg.tmp /usr/share/keyrings/prosody-keyring.gpg"
    - creates: /usr/share/keyrings/prosody-keyring.gpg

prosody-repo:
  file.managed:
    - name: /etc/apt/sources.list.d/prosody.list
    - contents: "deb [signed-by=/usr/share/keyrings/prosody-keyring.gpg] http://packages.prosody.im/debian {{ grains.oscodename }} main"
    - require:
      - cmd: prosody-repo-key

prosody-repo-update:
  cmd.run:
    - name: apt-get update -o Dir::Etc::sourcelist=sources.list.d/prosody.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
    - onchanges:
      - file: prosody-repo

prosody-dependencies:
  pkg.installed:
    - pkgs:
      #- libssl-dev
      #- gcc
      - lua-basexx
      - lua-cjson
      #- lua-event
      - lua-cyrussasl
      - lua-inspect
      - lua-luaossl
      - lua-sec
      - lua-unbound
      - luarocks
      - lua5.3
      - liblua5.3-dev

old-prosody:
  pkg.removed:
    - name: prosody-0.11
    - required_in:
      pkg: prosody


{% for luapkg in [
  "net-url 0.9-1"
] %}
luarocks-{{ luapkg }}:
  cmd.run:
    - name: "luarocks install {{ luapkg }}"
    - unless: "luarocks list --porcelain {{ luapkg.split(' ')[0] }} | grep -q '{{ luapkg.split(' ')[1] }}'"
    - require:
      - pkg: prosody-dependencies
{% endfor %}{# luapkg #}
{#- accept full package versions (13.0.7-1~jammy2) as well as the legacy short form (13.0.2-1);
    the codename in a full version is replaced by the minion's so one pin works across releases #}
{%- set prosody_pin = jitsi.prosody.version | string %}
{%- if '~' in prosody_pin %}
{%-   set prosody_base, prosody_suffix = prosody_pin.split('~', 1) %}
{%-   set prosody_version = prosody_base ~ '~' ~ grains.oscodename ~ (prosody_suffix | regex_replace('^[a-z]+', '')) %}
{%- else %}
{%-   set prosody_version = prosody_pin ~ '~' ~ grains.oscodename ~ '1' %}
{%- endif %}
prosody:
  pkg.installed:
    - name: prosody
    - version: "{{ prosody_version }}"
    - hold: True
    - update_holds: True
    - require:
      - file: prosody-repo
      - cmd: prosody-repo-update
  service.running:
    - enable: True
    #- reload: True
    - watch:
      - file: /etc/prosody/prosody.cfg.lua
      - file: /etc/prosody/conf.d/{{ jitsi.public_domain }}.cfg.lua

{# download and extract prosody plugins of jitsi #}
download-jitsi-meet-prosody:
  file.managed:
    - source: https://download.jitsi.org/stable/jitsi-meet-prosody_{{ jitsi.jitsi_meet_prosody.version }}_all.deb
    - skip_verify: True
    - name: /var/cache/apt/archives/jitsi-meet-prosody.deb
    - required_in:
      - cmd: extract_prosody_modules

extract_prosody_modules:
  cmd.run:
    - name: dpkg -x /var/cache/apt/archives/jitsi-meet-prosody.deb /tmp/jitsi-prosody-modules
    - require:
      - file: download-jitsi-meet-prosody

copy-prosody-plugins:
  file.rename:
    - name: /usr/share/jitsi-meet/prosody-plugins
    - source: /tmp/jitsi-prosody-modules/usr/share/jitsi-meet/prosody-plugins
    - makedirs: True
    - force: True
    - require:
      - cmd: extract_prosody_modules

remove-temporary-files:
  file.absent:
    - names:
      - /var/cache/apt/archives/jitsi-meet-prosody.deb
      - /tmp/jitsi-prosody-modules
    - require:
      - file: copy-prosody-plugins
    - require_in:
      - service: prosody

/etc/prosody/prosody.cfg.lua:
  file.managed:
    - source: salt://jitsi/prosody/prosody.cfg.lua.jinja
    - template: jinja

/etc/prosody/conf.d/{{ jitsi.public_domain }}.cfg.lua:
  file.managed:
    - source: salt://jitsi/prosody/domain.cfg.lua.jinja
    - makedirs: True
    - template: jinja

/etc/systemd/system/prosody.service.d/override.conf:
  file.managed:
    - makedirs: True
    - contents: |
        [Unit]
        Wants=nebula.service
        After=nebula.service
        [Service]
        LimitNOFILE=65000:65000

jicofo-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.jicofo.username }} {{ jitsi.xmpp.auth_domain }} {{ jitsi.jicofo.password }}"
    - creates: /var/lib/prosody/{{ jitsi.xmpp.auth_domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.jicofo.username }}.dat

jicofo-mod_roster:
  cmd.run:
    - name: "prosodyctl mod_roster_command subscribe focus.{{ jitsi.public_domain }} {{ jitsi.jicofo.username }}@{{ jitsi.xmpp.auth_domain }}"

jvb-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.videobridge.username }} {{ jitsi.xmpp.auth_domain }} {{ jitsi.videobridge.password }}"
    - creates: /var/lib/prosody/{{ jitsi.xmpp.auth_domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.videobridge.username }}.dat

{%- if jitsi.jibri_enabled %}
jibri-control-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.jibri.xmpp.control_login.username }} {{ jitsi.jibri.xmpp.control_login.domain }} {{ jitsi.jibri.xmpp.control_login.password }}"
    - creates: /var/lib/prosody/{{ jitsi.jibri.xmpp.control_login.domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.jibri.xmpp.control_login.username }}.dat

jibri-recorder-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.jibri.xmpp.call_login.username }} {{ jitsi.jibri.xmpp.call_login.domain }} {{ jitsi.jibri.xmpp.call_login.password }}"
    - creates: /var/lib/prosody/{{ jitsi.jibri.xmpp.call_login.domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.jibri.xmpp.call_login.username }}.dat
{% endif %}

{%- if jitsi.transcription.enabled %}
{%- set recorder_domain = "recorder." ~ jitsi.public_domain %}
transcriber-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.transcription.transcriber_username }} {{ recorder_domain }} {{ jitsi.transcription.transcriber_password }}"
    - creates: /var/lib/prosody/{{ recorder_domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.transcription.transcriber_username }}.dat

jigasi-auth:
  cmd.run:
    - name: "prosodyctl register {{ jitsi.transcription.jigasi_username }} {{ jitsi.xmpp.auth_domain }} {{ jitsi.transcription.jigasi_password }}"
    - creates: /var/lib/prosody/{{ jitsi.xmpp.auth_domain.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.transcription.jigasi_username }}.dat
{% endif %}

{%- if jitsi.visitors.enabled %}
{#- visitor prosodies (vnodes), see jitsi-meet resources/extra-large-conference #}
/etc/systemd/system/prosody-v@.service:
  file.managed:
    - source: salt://jitsi/prosody/files/prosody-v@.service

prosody-v-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/prosody-v@.service

{%- set vauth = "auth." ~ jitsi.visitors.domain %}
{%- for i in range(1, jitsi.visitors.vnodes | int + 1) %}

/etc/prosody-v{{ i }}/prosody.cfg.lua:
  file.managed:
    - source: salt://jitsi/prosody/prosody-v.cfg.lua.jinja
    - template: jinja
    - makedirs: True
    - user: root
    - group: prosody
    - mode: "0640"
    - context:
        vnode: {{ i }}
    - require:
      - pkg: prosody

/etc/prosody-v{{ i }}/certs:
  file.symlink:
    - target: /etc/prosody/certs
    - makedirs: True

prosody-v@{{ i }}:
  service.running:
    - enable: True
    - require:
      - cmd: prosody-v-daemon-reload
      - file: /etc/prosody-v{{ i }}/certs
      - file: copy-prosody-plugins
    - watch:
      - file: /etc/prosody-v{{ i }}/prosody.cfg.lua
      - file: /etc/systemd/system/prosody-v@.service

jicofo-auth-v{{ i }}:
  cmd.run:
    - name: "prosodyctl --config /etc/prosody-v{{ i }}/prosody.cfg.lua register {{ jitsi.jicofo.username }} {{ vauth }} {{ jitsi.jicofo.password }}"
    - creates: /var/lib/prosody-v{{ i }}/{{ vauth.replace('.', '%2e').replace('-', '%2d') }}/accounts/{{ jitsi.jicofo.username }}.dat
    - require:
      - service: prosody-v@{{ i }}
{% endfor %}{# vnode #}
{% endif %}{# visitors enabled #}

{% for domain in [ jitsi.public_domain , jitsi.xmpp.auth_domain ] %}
prosody-{{ domain }}-cert:
  cmd.run:
    - name: "yes '' | /usr/bin/prosodyctl cert generate {{ domain }}"
    - creates: /var/lib/prosody/{{ domain }}.crt

{% for ext in ["crt", "key"] %}
/etc/prosody/certs/{{ domain }}.{{ ext }}:
  file.symlink:
    - target: /var/lib/prosody/{{ domain }}.{{ ext }}

{% endfor %}{# ext #}
{% endfor %}{# domain #}

/usr/local/share/ca-certificates/{{ jitsi.xmpp.auth_domain }}.crt:
  file.symlink:
    - target: /var/lib/prosody/{{ jitsi.xmpp.auth_domain }}.crt

update-certificates:
  cmd.run:
    - name: "/usr/sbin/update-ca-certificates --fresh"

{# community modules which are neither in prosody core nor in jitsi-meet-prosody #}
{% for component in [
  "mod_reload_components",
  "mod_reload_modules" ,
 ] %}
/usr/lib/prosody/modules/{{ component }}.lua:
  file.managed:
    - source: https://hg.prosody.im/prosody-modules/raw-file/tip/{{ component }}/{{ component }}.lua
    - skip_verify: True
    - watch_in:
      - service: prosody

{% endfor %}{# for component #}

{#- These used to be fetched from jitsi-meet master / prosody-modules tip into the core module dir.
    jitsi-meet-prosody (plugin_paths) ships matching versions; stale copies would otherwise be picked up
    for modules upstream removed. mod_smacks is a prosody core module again and comes with the package. #}
stale-prosody-modules:
  file.absent:
    - names:
{%- for component in [
  "ext_events.lib",
  "mod_auth_token",
  "mod_av_moderation",
  "mod_av_moderation_component",
  "mod_client_proxy",
  "mod_conference_duration",
  "mod_conference_duration_component",
  "mod_end_conference",
  "mod_jitsi_session",
  "mod_muc_breakout_rooms",
  "mod_muc_domain_mapper",
  "mod_muc_lobby_rooms",
  "mod_muc_meeting_id",
  "mod_room_metadata",
  "mod_room_metadata_component",
  "mod_roster_command",
  "mod_speakerstats",
  "mod_speakerstats_component",
  "token_auth_utils.lib",
  "util.lib",
] %}
      - /usr/lib/prosody/modules/{{ component }}.lua
{%- endfor %}
    - watch_in:
      - service: prosody

{% endif %}{# if jitsi.prosody.enabled #}
