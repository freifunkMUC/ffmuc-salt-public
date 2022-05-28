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
  - sudo

icinga2-repo-key:
  cmd.run:
    - name: "curl https://packages.icinga.org/icinga.key | gpg --dearmor -o /usr/share/keyrings/icinga2-keyring.gpg"
    - creates: /usr/share/keyrings/icinga2-keyring.gpg

icinga2-repo:
  pkgrepo.managed:
    {% if grains.osfullname in 'Raspbian' %}
    - name: deb [signed-by=/usr/share/keyrings/icinga2-keyring.gpg] https://packages.icinga.com/raspbian icinga-{{ grains.oscodename }} main
    {% elif grains.osfullname in 'Ubuntu' %}
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/icinga2-keyring.gpg] https://packages.icinga.com/{{ grains.lsb_distrib_id | lower }} icinga-{{ grains.oscodename }} main
    {% else %}
    - name: deb [signed-by=/usr/share/keyrings/icinga2-keyring.gpg] https://packages.icinga.com/debian icinga-{{ grains.oscodename }} main
    {% endif %}
    - file: /etc/apt/sources.list.d/icinga2.list
    - clean_file: True
    - require:
      - cmd: icinga2-repo-key

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

# Install plugins (official + our own)
monitoring-plugin-pkgs:
  pkg.installed:
    - pkgs:
      - monitoring-plugins
      - nagios-plugins-contrib
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

icinga2-ca:
  file.symlink:
    - name: /var/lib/icinga2/certs/ca.crt
    - target: /etc/ssl/certs/ffmuc-cacert.pem
    - force: True
    - require:
      - pkg: icinga2-pkg

# Install and activate Icinga2 features
{% for feature in icinga2_features %}
/etc/icinga2/features-available/{{ feature }}.conf:
  file.managed:
    - source: salt://icinga2/features/{{ feature }}.conf
    - template: jinja
    - require:
      - pkg: icinga2
    - watch_in:
      - service: icinga2

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
{% for node_id,data in salt['mine.get']('netbox:tag_list:icinga2_client', 'minion_id', tgt_type='pillar').items() %}
/etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/{{ node_id }}.conf:
  file.managed:
    - source: salt://icinga2/host.conf.tmpl
    - template: jinja
    - context:
      node_id: {{ node_id }}
      node_config: {{ data }}
    - require:
      - file: Create /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - require_in:
      - file: Cleanup /etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/
    - watch_in:
      - service: icinga2-service
  {% endfor %}

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
      - service: icinga2
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
