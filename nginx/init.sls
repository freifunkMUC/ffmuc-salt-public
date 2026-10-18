###
# nginx
###
{#- Default to '' rather than to the same lookup again: an unset role made
    this None, and `'... ' in None` aborts the render with a TypeError. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}
{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
{% if not "jitsi meet" in role and ("webserver" in role or "webserver" in tags) %}

{% set behind_haproxy = 'haproxy' in salt['pillar.get']('netbox:tag_list', []) %}
{% set sslPort = 443 %}
{% if behind_haproxy %}
{% set sslPort = 8843 %}{# not enabled during testing #}
{% endif %}

nginx-repo-key:
  cmd.run:
    - name: "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg.tmp && mv /usr/share/keyrings/nginx-archive-keyring.gpg.tmp /usr/share/keyrings/nginx-archive-keyring.gpg"
    - creates: /usr/share/keyrings/nginx-archive-keyring.gpg

/etc/apt/sources.list.d/nginx.list:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/{{ grains.os | lower }} {{ grains.oscodename }} nginx
    - file: /etc/apt/sources.list.d/nginx.list
    - clean_file: True
    - require:
      - cmd: nginx-repo-key

{%- set nginx_pkg_version = salt['config.get']('netbox:config_context:nginx:version', '1.30.6-1~' ~ grains.oscodename) %}
nginx:
  pkg.installed:
    - name: nginx
    - version: '{{ nginx_pkg_version }}'
    - require:
      - pkgrepo: /etc/apt/sources.list.d/nginx.list
  service.running:
    - enable: TRUE
    - reload: TRUE
    - require:
      - pkg: nginx
    - watch:
      - cmd: nginx-configtest

# Test configuration before reload
nginx-configtest:
  cmd.run:
    - name: /usr/sbin/nginx -t

{# On the webfrontends /etc/resolv.conf points at the anycast resolvers, which are answered by the local dnsdist.
   At boot nginx started before dnsdist, could not resolve its proxy_pass upstreams (e.g. docker04.ov.ffmuc.net)
   and failed for good (Restart=no), so haproxy's "servers" backend answered 503 until nginx was started by hand. #}
nginx-systemd-ordering:
  file.managed:
    - name: /etc/systemd/system/nginx.service.d/ffmuc-ordering.conf
    - makedirs: True
    - contents: |
        # Managed by Salt (nginx/init.sls)
        [Unit]
        After=dnsdist.service pdns-recursor.service nebula.service
        StartLimitIntervalSec=300
        StartLimitBurst=30

        [Service]
        Restart=on-failure
        RestartSec=5s

nginx-systemd-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: nginx-systemd-ordering

# Disable default configuration
/etc/nginx/sites-enabled/default:
  file.absent:
    - watch_in:
      - cmd: nginx-configtest

# Remove nginx package's default.conf (it listens on port 80, HAProxy handles that)
# firmware.ffmuc.net.conf serves as our default_server
/etc/nginx/conf.d/default.conf:
  file.absent:
    - watch_in:
      - cmd: nginx-configtest



/etc/nginx/nginx.conf:
  file.managed:
    - source: salt://nginx/files/nginx.conf.jinja
    - template: jinja
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: nginx-configtest


{% set domains = ['vpn.ffmuc.net', 'vms.ffmuc.net', 'mitglieder.ffmuc.net', 'spende.ffmuc.net', 'dns-setup.ffmuc.net'] %}
{% for domain in domains %}
/srv/www/{{ domain }}:
  file.directory:
    - user: www-data
    - group: www-data
    - mode: '0755'
    - makedirs: True

/srv/www/{{ domain }}/index.html:
  file.managed:
    - source: salt://nginx/websites/{{ domain }}.html
    - user: www-data
    - group: www-data
    - mode: '0755'
{% endfor %}

/srv/www/firmware.ffmuc.net:
  file.directory

/srv/www/firmware.ffmuc.net/.gluon-firmware-selector:
  git.latest:
    - name: https://github.com/freifunkMUC/gluon-firmware-selector.git
    - rev: main-ffmuc
    - target: /srv/www/firmware.ffmuc.net/.gluon-firmware-selector
    - force_reset: True
    # force fetching is required as the repo is force-pushed
    - force_fetch: True
    - require:
      - file: /srv/www/firmware.ffmuc.net

/srv/www/firmware.ffmuc.net/.gluon-firmware-selector/config.js:
  file.managed:
    - source: salt://nginx/files/config.js
    - user: www-data
    - group: www-data
    - mode: '0644'
    - require:
      - git: /srv/www/firmware.ffmuc.net/.gluon-firmware-selector

/srv/www/firmware.ffmuc.net/device-pictures:
  git.latest:
    - name: https://github.com/freifunk/device-pictures.git
    - rev: main
    - target: /srv/www/firmware.ffmuc.net/device-pictures
    - force_reset: True
    - require:
      - file: /srv/www/firmware.ffmuc.net

{% for domain in salt['pillar.get']('netbox:config_context:webserver:domains') %}
/etc/nginx/sites-enabled/{{ domain }}.conf:
  file.managed:
    - source:
        - salt://nginx/domains/{{ domain }}.conf
        - salt://nginx/files/nginx_vhost.jinja2
    - makedirs: True
    - defaults:
        domain: {{ domain }}
        behind_haproxy: {{ behind_haproxy }}
        sslPort: {{ sslPort }}
    - template: jinja
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: nginx-configtest

{% if domain == "recorder.ffmuc.net" %}
/srv/www/recorder.ffmuc.net:
  file.recurse:
    - source: salt://nginx/files/recorder.ffmuc.net
    - clean: True
{% endif %}{# if domain == "recorder.ffmuc.net" #}

{% if domain == "apt.ffmuc.net" %}
{% for old in ["nebula", "systemd-packages", "ifupdown2_1.2.8-1_all.deb",
               "jitsi-videobridge2_2.1-394-g36698039-1_all.deb", "yanic_1.2.1-1_amd64.deb", "yanic_1.5.2-2_amd64.deb",
               "yanic_1.8.3-2_amd64.deb"] %}
/srv/www/apt.ffmuc.net/{{ old }}:
  file.absent
{% endfor %}
{% for n in range(17, 29) %}
/srv/www/apt.ffmuc.net/yanic-0.0.2-{{ n }}.deb:
  file.absent
{% endfor %}

/var/cache/nginx-apt:
  file.absent:
    - require:
      - file: /etc/nginx/sites-enabled/apt.ffmuc.net.conf
{% endif %}{# if domain == "apt.ffmuc.net" #}

{% endfor %}{# domain #}

{% for stream in salt['pillar.get']('netbox:config_context:webserver:streams') %}
/etc/nginx/streams-enabled/{{ stream }}.conf:
  file.managed:
    - source: salt://nginx/files/{{ stream }}_stream.conf
    - makedirs: True
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: nginx-configtest
{% endfor %}{# stream #}

{% for config in ["cloudflare-realips", "log_json"] %}
/etc/nginx/conf.d/{{ config }}.conf:
  file.managed:
    - source: salt://nginx/files/{{ config }}.conf.jinja
    - makedirs: True
    - template: jinja
    - require:
      - pkg: nginx
    - require_in:
      - service: nginx
{% endfor %}{# config #}

/etc/nginx/sites-enabled/ffmuc.net.include:
  file.managed:
    - source: salt://nginx/domains/ffmuc.net.include
    - makedirs: True
    - template: jinja
    - require:
      - pkg: nginx
    - require_in:
      - service: nginx

{% if "ffmuc.net" in salt['pillar.get']('netbox:config_context:webserver:domains') %}
/srv/www/ffmuc.net:
    file.directory:
      - user: deploy-ffmuc
      - group: deploy-ffmuc
      - mode: '0755'

/srv/www/ffmuc.net/.ssh:
    file.directory:
      - user: deploy-ffmuc
      - group: deploy-ffmuc
      - mode: '0700'

/srv/www/ffmuc.net/.ssh/id_ed25519:
    file.managed:
      - contents_pillar: netbox:config_context:ffmuc-net_deploy:ssh_privkey
      - user: deploy-ffmuc
      - group: deploy-ffmuc
      - mode: '0600'

/srv/www/ffmuc.net/.ssh/id_ed25519.pub:
    file.managed:
      - contents_pillar: netbox:config_context:ffmuc-net_deploy:ssh_pubkey
      - user: deploy-ffmuc
      - group: deploy-ffmuc
      - mode: '0644'

/srv/www/ffmuc.net/.ssh/authorized_keys:
    file.managed:
      - contents_pillar: netbox:config_context:ffmuc-net_deploy:ssh_pubkey
      - user: deploy-ffmuc
      - group: deploy-ffmuc
      - mode: '0640'

{% endif %}{# "ffmuc.net" in salt['pillar.get']('netbox:config_context:webserver:domains') #}

/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://nginx/files/logrotate.conf

{% endif %}{# webserver in role #}
