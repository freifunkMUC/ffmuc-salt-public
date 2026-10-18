###
# nginx frontend on the jicofo hosts (webfrontends/haproxy -> nginx:443 here)
# Split from the generic nginx state, which excludes the "jitsi meet" role.
###

jitsi-nginx-repo-key:
  cmd.run:
    - name: "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg.tmp && mv /usr/share/keyrings/nginx-archive-keyring.gpg.tmp /usr/share/keyrings/nginx-archive-keyring.gpg"
    - creates: /usr/share/keyrings/nginx-archive-keyring.gpg

jitsi-nginx-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/{{ grains.os | lower }} {{ grains.oscodename }} nginx
    - file: /etc/apt/sources.list.d/nginx.list
    - clean_file: True
    - require:
      - cmd: jitsi-nginx-repo-key

jitsi-nginx:
  pkg.installed:
    - name: nginx
    - require:
      - pkgrepo: jitsi-nginx-repo
  service.running:
    - name: nginx
    - enable: True
    - reload: True
    - require:
      - pkg: jitsi-nginx
    - watch:
      - cmd: jitsi-nginx-configtest

# only reload if the full config is valid
jitsi-nginx-configtest:
  cmd.run:
    - name: /usr/sbin/nginx -t
    - onchanges:
      - file: jitsi-nginx-config

jitsi-nginx-config:
  file.managed:
    - names:
      - /etc/nginx/nginx.conf:
        - source: salt://jitsi/nginx/files/nginx.conf.jinja
        - template: jinja
      - /etc/nginx/conf.d/cloudflare-realips.conf:
        - source: salt://jitsi/nginx/files/cloudflare-realips.conf
      - /etc/nginx/conf.d/log_json.conf:
        - source: salt://jitsi/nginx/files/log_json.conf
      - /etc/nginx/sites-enabled/meet.ffmuc.net.conf:
        - source: salt://jitsi/nginx/domains/meet.ffmuc.net.conf
        - template: jinja
      - /etc/nginx/sites-enabled/stub_status.conf:
        - source: salt://jitsi/nginx/files/stub_status.conf.jinja
        - template: jinja
    - makedirs: True
    - require:
      - pkg: jitsi-nginx

/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://jitsi/nginx/files/logrotate.conf
