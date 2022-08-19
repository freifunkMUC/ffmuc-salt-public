###
# nginx
###
{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:device_role:name')) %}
{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
{% if "webserver" in role or "webserver" in tags %}

nginx-repo-key:
  cmd.run:
    - name: "curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg"
    - creates: /usr/share/keyrings/nginx-archive-keyring.gpg

/etc/apt/sources.list.d/nginx.list:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/{{ grains.os | lower }} {{ grains.oscodename }} nginx
    - file: /etc/apt/sources.list.d/nginx.list
    - clean_file: True
    - require:
      - cmd: nginx-repo-key

nginx:
  pkg.installed:
    - name: nginx
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

# Disable default configuration
/etc/nginx/sites-enabled/default:
  file.absent:
    - watch_in:
      - cmd: nginx-configtest

{% if salt["service.available"]("nginx") %}
{% set nginx_version = salt["pkg.info_installed"]("nginx").get("nginx", {}).get("version","").split("-")[0] %}
{% else %}
{% set nginx_version = "1.18.0" %}{# current on 02.11.2020 #}
{% endif %}

{% for module in ["http_brotli_filter_module", "http_brotli_static_module", "http_fancyindex_module"] %}
nginx-module-{{ module }}:
  file.managed:
    - name: /usr/lib/nginx/modules/ngx_{{ module }}.so
    - source: https://mirror.krombel.de/nginx-{{ nginx_version }}/ngx_{{ module }}.so
    - skip_verify: True
    - watch_in:
      - cmd: nginx-configtest
{% endfor %}

/etc/nginx/nginx.conf:
  file.managed:
    - source: salt://nginx/files/nginx.conf.jinja
    - template: jinja
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: nginx-configtest


{% for domain in salt['pillar.get']('netbox:config_context:webserver:domains') %}
/etc/nginx/sites-enabled/{{ domain }}.conf:
  file.managed:
    - source:
        - salt://nginx/domains/{{ domain }}.conf
        - salt://nginx/files/nginx_vhost.jinja2
    - makedirs: True
    - defaults:
        domain: {{ domain }}
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

/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://nginx/files/logrotate.conf

{% endif %}{# webserver in role #}
