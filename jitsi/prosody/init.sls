##
# Prosody for jitsi (WIP)
##
{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.prosody.enabled %}

prosody-repo-key:
  cmd.run:
    - name: "curl https://prosody.im/files/prosody-debian-packages.key | gpg --dearmor -o /usr/share/keyrings/prosody-keyring.gpg"
    - creates: /usr/share/keyrings/prosody-keyring.gpg

prosody-repo:
  pkgrepo.managed:
    - humanname: Prosody
    - name: deb [signed-by=/usr/share/keyrings/prosody-keyring.gpg] http://packages.prosody.im/debian {{ grains.oscodename }} main
    - file: /etc/apt/sources.list.d/prosody.list
    - clean_file: True
    - require:
      - cmd: prosody-repo-key

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
    - require:
      - pkg: prosody-dependencies
{% endfor %}{# luapkg #}
prosody:
  pkg.installed:
    - name: prosody
    - version: "{{ jitsi.prosody.version }}~{{ grains.oscodename }}1"
    - hold: True
    - require:
      - pkgrepo: prosody-repo
  service.running:
    - enable: True
    #- reload: True
    - watch:
      - file: /etc/prosody/prosody.cfg.lua
      - file: /etc/prosody/conf.d/{{ jitsi.public_domain }}.cfg.lua

{# download and extract prosody plugins of jitsi #}
download-jitsi-meet-prosody:
  file.managed:
    - source: https://download.jitsi.org/stable/jitsi-meet-prosody_1.0.7874-1_all.deb
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

{% for component in [
  "mod_auth_token",
  "mod_client_proxy",
  "mod_reload_components",
  "mod_reload_modules" ,
  "mod_roster_command",
  "mod_smacks",
 ] %}
/usr/lib/prosody/modules/{{ component }}.lua:
  file.managed:
    - source: https://hg.prosody.im/prosody-modules/raw-file/tip/{{ component }}/{{ component }}.lua
    - skip_verify: True
    - watch_in:
      - service: prosody

{% endfor %}{# for component #}

/usr/lib/prosody/modules/token_auth_utils.lib.lua:
  file.managed:
    - source: https://hg.prosody.im/prosody-modules/raw-file/tip/mod_auth_token/token_auth_utils.lib.lua
    - skip_verify: True
    - watch_in:
      - service: prosody

{% for component in [
  "ext_events.lib",
  "mod_av_moderation",
  "mod_av_moderation_component",
  "mod_end_conference",
  "mod_conference_duration",
  "mod_conference_duration_component",
  "mod_jitsi_session",
  "mod_muc_breakout_rooms",
  "mod_muc_domain_mapper",
  "mod_muc_lobby_rooms",
  "mod_muc_meeting_id",
  "mod_room_metadata",
  "mod_room_metadata_component",
  "mod_speakerstats",
  "mod_speakerstats_component",
  "util.lib",
] %}
/usr/lib/prosody/modules/{{ component }}.lua:
#/usr/share/jitsi-meet/prosody-plugins/{{ component }}.lua:
  file.managed:
    - source: https://raw.githubusercontent.com/jitsi/jitsi-meet/master/resources/prosody-plugins/{{ component }}.lua
    - skip_verify: True
    - watch_in:
      - service: prosody
{% endfor %}{# for component #}

{% endif %}{# if jitsi.prosody.enabled #}
