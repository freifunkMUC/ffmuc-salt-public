#
# Icinga2
#
{%- if 'icinga2_server' in salt['pillar.get']('netbox:tag_list', [])  or 'icinga2_client' in salt['pillar.get']('netbox:tag_list', []) %}


{%- if 'icinga2_server' in salt['pillar.get']('netbox:tag_list', []) %}
# server should send states to graylog
{%- set icinga2_features = ["api", "gelf"] %}
{%- else %}
# Nodes should accept config and commands from Icinga2 server
{%- set icinga2_features = ["api"] %}
{%- endif %}

include:
  - apt
  - certs
  - sudo

{%- if grains.os == 'Raspbian' %}
# packages.icinga.com/raspbian has no bookworm and debian has no armhf: use Raspbian's icinga2
# (2.13, agent older than the master is supported); the pin also replaces leftovers of the
# icinga-bullseye packages, which are not installable on bookworm
/etc/apt/sources.list.d/icinga2.list:
  file.absent:
    - require_in:
      - pkg: icinga2-pkg

/etc/apt/preferences.d/icinga2:
  file.managed:
    - contents: |
        Package: icinga2*
        Pin: origin raspbian.raspberrypi.org
        Pin-Priority: 1001
    - require_in:
      - pkg: icinga2-pkg
{%- else %}
icinga2-repo-key:
  file.managed:
    - name: /usr/share/keyrings/icinga2-keyring.asc
    - source: https://packages.icinga.com/icinga.key
    # follows Icinga key rotations; re-downloads only when the ETag changes
    - skip_verify: True
    - use_etag: True
    - mode: "0644"

/usr/share/keyrings/icinga2-keyring.gpg:
  file.absent:
    - require:
      - pkgrepo: icinga2-repo

icinga2-repo:
  pkgrepo.managed:
    {% if grains.osfullname in 'Ubuntu' %}
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/icinga2-keyring.asc] https://packages.icinga.com/{{ grains.lsb_distrib_id | lower }} icinga-{{ grains.oscodename }} main
    {% else %}
    - name: deb [signed-by=/usr/share/keyrings/icinga2-keyring.asc] https://packages.icinga.com/debian icinga-{{ grains.oscodename }} main
    {% endif %}
    - file: /etc/apt/sources.list.d/icinga2.list
    - clean_file: True
    - require:
      - file: icinga2-repo-key
{%- endif %}

# Install icinga2 package
{% set node_config = salt['pillar.get']('nodes:' ~ grains.id, {}) %}
icinga2-pkg:
  pkg.latest:
    - name: icinga2
    - refresh: True

icinga2-service:
  service.running:
    - name: icinga2
    - enable: True
    - reload: True
    - require:
      - user: icinga-user
      - file: icinga2-ca
      - file: icinga2-hostcert
      - file: icinga2-hostkey
      - file: /etc/icinga2/repository.d

# a reload did not reach the daemon the package had started (ft02/ft03, 19.10.2026): restart once after install or upgrade
icinga2-restart-after-pkg:
  service.running:
    - name: icinga2
    - watch:
      - pkg: icinga2-pkg
    - require:
      - service: icinga2-service

# Install plugins (official + our own)
monitoring-plugin-pkgs:
  pkg.installed:
    - pkgs:
      - monitoring-plugins
      {#- renamed in Debian 13 and Ubuntu 26.04 #}
      {%- set contrib_renamed = (grains.os == 'Debian' and grains.osmajorrelease >= 13)
                                or (grains.os == 'Ubuntu' and grains.osmajorrelease >= 26) %}
      - {{ 'monitoring-plugins-contrib' if contrib_renamed else 'nagios-plugins-contrib' }}
      - libyaml-syck-perl
      - libmonitoring-plugin-perl
      - lsof
    - watch_in:
      - service: icinga2-service

ffho-plugins:
  file.recurse:
    - name: /usr/local/share/monitoring-plugins/
    - source: salt://icinga2/plugins/
    - file_mode: "0755"
    - dir_mode: "0755"
    - user: root
    - group: root

# Install sudoers file for Icinga2 checks
/etc/sudoers.d/icinga2:
  file.managed:
    - source: salt://icinga2/icinga2.sudoers
    - mode: "0440"

icinga-user:
  user.present:
    - name: nagios
    - groups:
      - nagios
      - ssl-cert
    - require:
      - pkg: icinga2-pkg

# Icinga2 master config (for master and all nodes)
/etc/icinga2/icinga2.conf:
  file.managed:
    - source:
      - salt://icinga2/icinga2.conf.H_{{ grains.id }}
      - salt://icinga2/icinga2.conf
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service


# Add FFHOPluginDir
/etc/icinga2/constants.conf:
  file.managed:
    - source: salt://icinga2/constants.conf
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service


# Connect "master" and client zones
/etc/icinga2/zones.conf:
  file.managed:
    - source:
      - salt://icinga2/zones.conf.H_{{ grains.id }}
      - salt://icinga2/zones.conf
    - template: jinja
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service

/var/lib/icinga2/certs:
  file.directory:
    - mode: "0700"
    - user: nagios
    - group: nagios
    - require:
      - pkg: icinga2-pkg

{#- Before the first install there is no icinga2 binary and cmd.run would abort the render. #}
{%- set node_name = salt['cmd.run']('icinga2 variable get NodeName', python_shell=False, ignore_retcode=True).strip() if salt['cmd.which']('icinga2') else '' %}
{%- if not node_name or ' ' in node_name or '\n' in node_name or '/' in node_name %}{% set node_name = grains['id'] %}{% endif %}
# Install host cert + key readable for icinga
icinga2-hostcert:
  file.symlink:
    - name: /var/lib/icinga2/certs/{{ grains['id'] }}.crt
    - target: /etc/ssl/certs/{{ grains['id'] }}.cert.pem
    - force: True
    - require:
      - pkg: icinga2-pkg
      - file: /var/lib/icinga2/certs
    - watch_in:
      - service: icinga2-service

icinga2-hostkey:
  file.symlink:
    - name: /var/lib/icinga2/certs/{{ grains['id'] }}.key
    - target: /etc/ssl/private/{{ grains['id'] }}.key.pem
    - force: True
    - require:
      - pkg: icinga2-pkg
      - file: /var/lib/icinga2/certs
    - watch_in:
      - service: icinga2-service

{%- if node_name != grains['id'] %}
# NodeName is the short hostname on some hosts: link the cert under that name too, old files kept as *.bak
icinga2-hostcert-nodename:
  file.symlink:
    - name: /var/lib/icinga2/certs/{{ node_name }}.crt
    - target: /etc/ssl/certs/{{ grains['id'] }}.cert.pem
    - force: True
    - backupname: /var/lib/icinga2/certs/{{ node_name }}.crt.bak
    - require:
      - pkg: icinga2-pkg
      - file: /var/lib/icinga2/certs
    - watch_in:
      - service: icinga2-service

icinga2-hostkey-nodename:
  file.symlink:
    - name: /var/lib/icinga2/certs/{{ node_name }}.key
    - target: /etc/ssl/private/{{ grains['id'] }}.key.pem
    - force: True
    - backupname: /var/lib/icinga2/certs/{{ node_name }}.key.bak
    - require:
      - pkg: icinga2-pkg
      - file: /var/lib/icinga2/certs
    - watch_in:
      - service: icinga2-service
{%- endif %}

{%- set v2_bundle = salt['pillar.get']('netbox:config_context:certs:trust_v2', false) and 'BEGIN CERTIFICATE' in salt['cp.get_file_str']('salt://certs/ffmuc-cacert-v2.pem') %}
icinga2-ca:
  file.symlink:
    - name: /var/lib/icinga2/certs/ca.crt
    - target: {{ '/etc/ssl/ffmuc-ca-bundle.pem' if v2_bundle else '/etc/ssl/certs/ffmuc-cacert.pem' }}
    - force: True
    - require:
      - pkg: icinga2-pkg
      - file: /var/lib/icinga2/certs
      {%- if v2_bundle %}
      - file: /etc/ssl/ffmuc-ca-bundle.pem
      {%- endif %}
    - watch_in:
      - service: icinga2-service

# the host cert behind the symlink gets renewed
icinga2-hostcert-fingerprint:
  cmd.run:
    - name: openssl x509 -noout -fingerprint -sha256 -in /etc/ssl/certs/{{ grains['id'] }}.cert.pem > /var/lib/icinga2/hostcert.fingerprint
    - unless: openssl x509 -noout -fingerprint -sha256 -in /etc/ssl/certs/{{ grains['id'] }}.cert.pem | cmp -s - /var/lib/icinga2/hostcert.fingerprint
    - require:
      - file: icinga2-hostcert

# a reload keeps the old certificate on the ApiListener: restart when the host cert or the CA changes
icinga2-restart-on-cert:
  service.running:
    - name: icinga2
    - watch:
      - cmd: icinga2-hostcert-fingerprint
      - file: icinga2-ca
      {%- if node_name != grains['id'] %}
      - file: icinga2-hostcert-nodename
      - file: icinga2-hostkey-nodename
      {%- endif %}
    - require:
      - service: icinga2-service

# Install and activate Icinga2 features
{% for feature in icinga2_features %}
/etc/icinga2/features-available/{{ feature }}.conf:
  file.managed:
    - source: salt://icinga2/features/{{ feature }}.conf
    - template: jinja
    - require:
      - pkg: icinga2
    - watch_in:
      - service: icinga2-service

/etc/icinga2/features-enabled/{{ feature }}.conf:
  file.symlink:
    - target: "../features-available/{{ feature }}.conf"
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service
{% endfor %}


# Install command definitions
/etc/icinga2/commands.d:
  file.recurse:
    - source: salt://icinga2/commands.d
    - template: jinja
    - file_mode: "0644"
    - dir_mode: "0755"
    - user: root
    - group: root
    - clean: true
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service


# Create directory for ffho specific configs
/etc/icinga2/zones.d/master/ffmuc-conf.d:
  file.directory:
    - makedirs: true
    - require:
      - pkg: icinga2-pkg

/etc/icinga2/repository.d:
  file.directory:
    - makedirs: true
    - require:
      - pkg: icinga2-pkg


################################################################################
#                               Icinga2 Server                                 #
################################################################################
{% if 'icinga2_server' in salt['pillar.get']('netbox:tag_list', []) %}

# Install command definitions
/etc/icinga2/zones.d/master/ffmuc-conf.d/services:
  file.recurse:
    - source: salt://icinga2/services
    - file_mode: "0644"
    - dir_mode: "0755"
    - user: root
    - group: root
    - clean: true
    - template: jinja
    - require:
      - pkg: icinga2-pkg
    - watch_in:
      - service: icinga2-service


# Create client node/zone objects
Create /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/:
  file.directory:
    - name: /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - makedirs: true
    - require:
      - pkg: icinga2-pkg

Cleanup /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/:
  file.directory:
    - name: /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - clean: true
    - watch_in:
      - service: icinga2-service

  # Generate config file for every client known to pillar
{%- set icinga2_clients = salt['mine.get']('netbox:tag_list:icinga2_client', 'minion_id', tgt_type='pillar').keys() | list %}
{%- set icinga2_agentless = salt['mine.get']('netbox:tag_list:icinga2_agentless', 'minion_id', tgt_type='pillar').keys() | list %}
{% for node_id in icinga2_clients %}
/etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/{{ node_id }}.conf:
  file.managed:
    - source: salt://icinga2/host.conf.jinja
    - template: jinja
    - context:
        node_id: {{ node_id }}
    - require:
      - file: Create /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - require_in:
      - file: Cleanup /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - watch_in:
      - service: icinga2-service
  {% endfor %}

  # Minions without an agent (NetBox tag icinga2_agentless, e.g. the Jitsi hosts,
  # which cannot reach the master's overlay address): host checks from the master
{%- set external_ips = salt['mine.get']('*', 'minion_external_ip') %}
{%- set primary_ips = salt['mine.get']('*', 'minion_address') %}
{%- set roles = salt['mine.get']('*', 'minion_role') %}
{%- set locations = salt['mine.get']('*', 'minion_location') %}
{%- for node_id in icinga2_agentless if node_id not in icinga2_clients %}
  {%- set external = external_ips.get(node_id) or [] %}
  {%- set primary = primary_ips.get(node_id) or '' %}
  {%- set address = external[0] if external else primary | regex_replace('/\d+$', '') %}
  {%- if address %}
/etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/{{ node_id }}.conf:
  file.managed:
    - source: salt://icinga2/host_agentless.conf.jinja
    - template: jinja
    - context:
        node_id: {{ node_id }}
        address: {{ address | yaml_dquote }}
        role: {{ (roles.get(node_id) or '') | string | yaml_dquote }}
        location: {{ (locations.get(node_id) or '') | string | yaml_dquote }}
        notes: ""
    - require:
      - file: Create /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - require_in:
      - file: Cleanup /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - watch_in:
      - service: icinga2-service
  {%- endif %}
{%- endfor %}

  # Hosts that are no (working) minions, from icinga2/static_hosts.yaml
{%- import_yaml 'icinga2/static_hosts.yaml' as static_hosts %}
{%- for node_id, host in static_hosts.items() if node_id not in icinga2_clients and node_id not in icinga2_agentless %}
/etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/{{ node_id }}.conf:
  file.managed:
    - source: salt://icinga2/host_agentless.conf.jinja
    - template: jinja
    - context:
        node_id: {{ node_id }}
        address: {{ host.address | yaml_dquote }}
        role: {{ host.get('role', '') | yaml_dquote }}
        location: {{ host.get('location', '') | yaml_dquote }}
        notes: {{ host.get('notes', '') | yaml_dquote }}
    - require:
      - file: Create /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - require_in:
      - file: Cleanup /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - watch_in:
      - service: icinga2-service
{%- endfor %}

{%- set heartbeat_url = salt['config.get']('netbox:config_context:icinga2:heartbeat_url', '') %}
# URL for check_heartbeat (NetBox config context icinga2.heartbeat_url)
/etc/icinga2/heartbeat.url:
{%- if heartbeat_url %}
  file.managed:
    - contents: {{ heartbeat_url | yaml_dquote }}
    - mode: "0640"
    - user: root
    - group: nagios
    - show_changes: False
    - require:
      - user: icinga-user
{%- else %}
  file.absent
{%- endif %}

/etc/icinga2/scripts/mattermost-notifications.py:
  file.managed:
    - source: salt://icinga2/mattermost-notifications.py
    - template: jinja
    - mode: "0755"
    - user: root
    - group: root

/etc/icinga2/conf.d/commands.conf:
  file.managed:
    - source: salt://icinga2/commands.conf
    - mode: "0644"
    - user: root
    - group: root
    - watch_in:
      - service: icinga2-service

/etc/icinga2/conf.d/notifications.conf:
  file.managed:
    - source: salt://icinga2/notifications.conf
    - mode: "0644"
    - user: root
    - group: root
    - watch_in:
      - service: icinga2-service

/etc/icinga2/conf.d/templates.conf:
  file.managed:
    - source: salt://icinga2/templates.conf
    - mode: "0644"
    - user: root
    - group: root
    - watch_in:
      - service: icinga2-service

/etc/icinga2/conf.d/users.conf:
  file.managed:
    - source: salt://icinga2/users.conf.tmpl
    - mode: "0644"
    - user: root
    - group: root
    - template: jinja
    - show_changes: False
    - watch_in:
      - service: icinga2-service

/etc/icinga2/conf.d/services.conf:
  file.managed:
    - source: salt://icinga2/services.conf.tmpl
    - mode: "0644"
    - user: root
    - group: root
    - template: jinja
    - watch_in:
      - service: icinga2-service

################################################################################
#                               Icinga2 Client                                 #
################################################################################
{% else %}

/etc/icinga2/check-commands.conf:
  file.absent:
    - watch_in:
      - service: icinga2-service
{% endif %}




################################################################################
#                              Check related stuff                             #
################################################################################
/etc/icinga2/zones.d/master/ffmuc-conf.d/bird_ospf_interfaces_down_ok.txt:
  file.managed:
    - source: salt://icinga2/bird_ospf_interfaces_down_ok.txt.tmpl
    - template: jinja
    - require:
      - file: /etc/icinga2/zones.d/master/ffmuc-conf.d
{% endif %}
