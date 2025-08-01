###
# nginx
###
{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:role:name')) %}
{% set tags = salt['pillar.get']('netbox:tag_list', []) %}
{% if "parker-gateway" in role %}
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

# Disable default configuration from older nginx releases
/etc/nginx/sites-enabled/default:
  file.absent:
    - watch_in:
      - cmd: nginx-configtest

/etc/nginx/conf.d/default.conf:
  file.absent:
    - watch_in:
      - cmd: nginx-configtest

/etc/nginx/sites-enabled/:
  file.directory:
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

{% if salt["service.available"]("nginx") %}
{% set nginx_version = salt["pkg.info_installed"]("nginx").get("nginx", {}).get("version","").split("-")[0] %}
{% else %}
{% set nginx_version = "1.26.2" %}{# current on 02.11.2020 #}
{% endif %}


/etc/nginx/nginx.conf:
  file.managed:
    - source: salt://nginx/files/nginx.conf.jinja
    - template: jinja
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: nginx-configtest

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


/etc/nginx/sites-enabled/wgkex-broker.conf:
  file.managed:
    - source: salt://parker/nginx/sites/wgkex-broker.conf
    - template: jinja
    - user: www-data
    - group: www-data
    - mode: '0755'


/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://nginx/files/logrotate.conf

{% endif %}{# parker-gateway in role #}
