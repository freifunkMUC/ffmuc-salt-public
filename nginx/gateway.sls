# nginx on the gateways: the default page on port 80 and, on gw04, the meshviewer-web vhost.
# nginx.org's nginx replaces Ubuntu's nginx and nginx-common. apt removes them, but keeps their
# config files (sites-available, sites-enabled, snippets) and does not touch /etc/letsencrypt.
include:
  - nginx.pkg

# Ubuntu's dynamic modules are built for Ubuntu's nginx and do not load into nginx.org's nginx.
nginx-gateway-ubuntu-modules:
  pkg.removed:
    - pkgs:
      - libnginx-mod-http-fancyindex
    - require_in:
      - pkg: nginx-pkg

# nginx.org's nginx.conf only includes conf.d; this one also includes sites-enabled and no modules-enabled.
/etc/nginx/nginx.conf:
  file.managed:
    - source: salt://nginx/files/gateway/nginx.conf
    - require:
      - pkg: nginx-pkg

/etc/nginx/sites-available/default:
  file.managed:
    - source: salt://nginx/files/gateway/default
    - require:
      - pkg: nginx-pkg

/etc/nginx/sites-enabled/default:
  file.symlink:
    - target: /etc/nginx/sites-available/default
    - force: True
    - require:
      - file: /etc/nginx/sites-available/default

# nginx.org's default server would also listen on port 80.
/etc/nginx/conf.d/default.conf:
  file.absent:
    - require:
      - pkg: nginx-pkg

/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://nginx/files/logrotate.conf
    - require:
      - pkg: nginx-pkg

nginx-gateway-configtest:
  cmd.run:
    - name: /usr/sbin/nginx -t
    - onchanges:
      - pkg: nginx-pkg
      - file: /etc/nginx/nginx.conf
      - file: /etc/nginx/sites-available/default
      - file: /etc/nginx/sites-enabled/default
      - file: /etc/nginx/conf.d/default.conf

# A reload keeps the old binary. After the package changes, start the new binary.
nginx-gateway-restart:
  cmd.run:
    - name: systemctl restart nginx
    - onchanges:
      - pkg: nginx-pkg
    - require:
      - cmd: nginx-gateway-configtest

nginx-gateway-service:
  service.running:
    - name: nginx
    - enable: True
    - reload: True
    - require:
      - cmd: nginx-gateway-restart
    - watch:
      - cmd: nginx-gateway-configtest
