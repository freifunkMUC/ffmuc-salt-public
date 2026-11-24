# nginx from nginx.org, shared by nginx (webfrontends) and nginx.gateway.
# Require it as `pkg: nginx-pkg`.
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

{%- set nginx_pkg_version = salt['config.get']('netbox:config_context:nginx:version', '1.30.8-1~' ~ grains.oscodename) %}
nginx-pkg:
  pkg.installed:
    - name: nginx
    - version: '{{ nginx_pkg_version }}'
    - require:
      - pkgrepo: /etc/apt/sources.list.d/nginx.list
