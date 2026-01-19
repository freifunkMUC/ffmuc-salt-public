#
# SSL Certificates
#

openssl:
  pkg.installed:
    - name: openssl

ssl-cert:
  pkg.installed

update_ca_certificates:
  cmd.run:
    - name: /usr/sbin/update-ca-certificates
    - onchanges:
      - file: /usr/local/share/ca-certificates/ffmuc-cacert.crt

generate-dhparam:
  cmd.run:
    - name: openssl dhparam -out /etc/ssl/dhparam.pem 4096
    - creates: /etc/ssl/dhparam.pem

# Install FFMUC internal CA into Debian CA certificate mangling mechanism so
# libraries (read: openssl) can use the CA cert when validating internal
# service certificates. By installing the cert into the local ca-certificates
# directory and calling update-ca-certificates two symlinks will be installed
# into /etc/ssl/certs which will both point to the crt file:
#  * ffmuc-cacert.pem
#  * <cn-hash>.pem
# The latter is use by openssl for validation.
/usr/local/share/ca-certificates/ffmuc-cacert.crt:
  file.managed:
    - source: salt://certs/ffmuc-cacert.pem
    - user: root
    - group: root
    - mode: "0644"
    - watch_in:
      - cmd: update_ca_certificates

{%- set cert_validity = salt['cmd.run']('openssl x509 -noout -checkend 2592000 -in /etc/ssl/certs/'~ grains['id']  ~'.cert.pem') %}
{%- if salt["network.ping"]("ca.ov.ffmuc.net", return_boolean=True, timeout=10) %}
{% if 'Certificate will not expire' not in cert_validity %}
{%- set cert_bundle = salt['cfssl_certs.request_cert']('https://ca.ov.ffmuc.net', grains['id']) %}
#
# Internal certificate from FFMUC CA
#

# Install found certificates
/etc/ssl/certs/{{ grains['id'] }}.cert.pem:
  file.managed:
    - contents: |
        {{ cert_bundle['certificate']|indent(8) }}
    - user: root
    - group: root
    - mode: "0644"

/etc/ssl/private/{{ grains['id'] }}.key.pem:
  file.managed:
    - contents: |
        {{ cert_bundle['private_key']|indent(8) }}
    - user: root
    - group: ssl-cert
    - mode: "0440"
    - require:
      - pkg: ssl-cert
{% endif %}{# Certificate wont expire #}
{% endif %}{# can ping ca #}

{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:role:name')) %}

{% set gcore_token = salt['pillar.get']('netbox:config_context:gcore:api_token') %}
{% set cloudflare_token = salt['pillar.get']('netbox:config_context:cloudflare:api_token') %}

{% if "webserver-external" in role %}
# Preparation / install deploy hooks
/etc/letsencrypt/archive/:
  file.directory:
    - group: ssl-cert
    - mode: "0750"
/etc/letsencrypt/live/:
  file.directory:
    - group: ssl-cert
    - mode: "0750"

/etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        systemctl reload nginx
    - mode: "0750"
    - makedirs: True

/etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        dnsdist -e "reloadAllCertificates()"
    - mode: "0750"
    - makedirs: True

/etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        systemctl reload haproxy
    - mode: "0750"
    - makedirs: True
{% endif %}{# if "webserver-external" in role #}

{% if "webserver-external" in role or "jitsi meet" in role %}
#
# Certbot (shared venv)
#

python3-venv:
  pkg.installed

python3-pip:
  pkg.installed

certbot-venv:
  cmd.run:
    - name: python3 -m venv /opt/certbot-venv
    - creates: /opt/certbot-venv/bin/python3
    - require:
      - pkg: python3-venv

certbot-venv-packages:
  pip.installed:
    - bin_env: /opt/certbot-venv/bin/pip
    - pkgs:
      - certbot>=2.0.0
    - require:
      - cmd: certbot-venv
      - pkg: python3-pip

/etc/systemd/system/certbot-renew.service:
  file.managed:
    - mode: "0644"
    - contents: |
        [Unit]
        Description=Renew Let's Encrypt certificates

        [Service]
        Type=oneshot
        ExecStart=/opt/certbot-venv/bin/certbot renew --quiet
    - require:
      - pip: certbot-venv-packages

/etc/systemd/system/certbot-renew.timer:
  file.managed:
    - mode: "0644"
    - contents: |
        [Unit]
        Description=Run certbot twice daily

        [Timer]
        OnCalendar=*-*-* 02,14:00:00
        RandomizedDelaySec=30m
        Persistent=true

        [Install]
        WantedBy=timers.target

systemd-daemon-reload-certbot-renew:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/certbot-renew.service
      - file: /etc/systemd/system/certbot-renew.timer

certbot-renew-timer:
  service.running:
    - name: certbot-renew.timer
    - enable: True
    - require:
      - cmd: systemd-daemon-reload-certbot-renew
{% endif %}{# if "webserver-external" in role or "jitsi meet" in role #}

{% if ("webserver-external" in role or "jitsi meet" in role) and gcore_token %}
#
# Certificate for ffmuc.net (Gcore DNS)
#

certbot-venv-gcore-plugin:
  pip.installed:
    - bin_env: /opt/certbot-venv/bin/pip
    - name: certbot-dns-gcore
    - require:
      - pip: certbot-venv-packages

dns_gcore_credentials:
  file.managed:
    - name: /var/lib/cache/salt/dns_gcore_credentials.ini
    - source: salt://certs/files/dns_gcore_credentials.ini
    - makedirs: True
    - mode: "0600"
    - template: jinja
    - defaults:
        gcore_token: {{ gcore_token }}

ffmuc-wildcard-cert:
  cmd.run:
    - name: >
        /opt/certbot-venv/bin/certbot certonly -n --agree-tos -m hilfe@ffmuc.net
        --cert-name ffmuc.net
        --authenticator dns-gcore
        --dns-gcore-credentials /var/lib/cache/salt/dns_gcore_credentials.ini
        --dns-gcore-propagation-seconds=80
        --preferred-challenges dns --expand
        -d "ffmuc.net"
        -d "*.ffmuc.net"
        -d "*.ext.ffmuc.net"
    - unless: >
        test -f /etc/letsencrypt/live/ffmuc.net/fullchain.pem &&
        openssl x509 -noout -checkend 2592000 -in /etc/letsencrypt/live/ffmuc.net/fullchain.pem
    - require:
      - pip: certbot-venv-gcore-plugin
      - file: dns_gcore_credentials
      {% if "webserver-external" in role %}
      - file: /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh
      {% endif %}{# if "webserver-external" in role #}
{% endif %}{# if ("webserver-external" in role or "jitsi meet" in role) and gcore_token #}


{% if ("webserver-external" in role or "jitsi meet" in role) and cloudflare_token %}
#
# Certificate for non-ffmuc.net domains (Cloudflare DNS)
#

certbot-venv-cloudflare-plugin:
  pip.installed:
    - bin_env: /opt/certbot-venv/bin/pip
    - name: certbot-dns-cloudflare
    - require:
      - pip: certbot-venv-packages

dns_cloudflare_credentials:
  file.managed:
    - name: /var/lib/cache/salt/dns_cloudflare_credentials.ini
    - source: salt://certs/files/dns_cloudflare_credentials.ini
    - makedirs: True
    - mode: "0600"
    - template: jinja
    - defaults:
        cloudflare_token: {{ cloudflare_token }}

ffmuc-cloudflare-domains-cert:
  cmd.run:
    - name: >
        /opt/certbot-venv/bin/certbot certonly -n --agree-tos -m hilfe@ffmuc.net
        --cert-name ffmuc-cloudflare
        --authenticator dns-cloudflare
        --dns-cloudflare-credentials /var/lib/cache/salt/dns_cloudflare_credentials.ini
        --dns-cloudflare-propagation-seconds=80
        --preferred-challenges dns --expand
        -d "ffmeet.net"
        -d "ffmuc.bayern"
        -d "*.ffmuc.bayern"
        -d "fnmuc.net"
        -d "*.fnmuc.net"
        -d "freie-netze.org"
        -d "freifunk-muenchen.de"
        -d "*.freifunk-muenchen.de"
        -d "freifunk-muenchen.net"
        -d "*.freifunk-muenchen.net"
        -d "xn--freifunk-mnchen-8vb.de"
        -d "*.xn--freifunk-mnchen-8vb.de"
    - unless: >
        test -f /etc/letsencrypt/live/ffmuc-cloudflare/fullchain.pem &&
        openssl x509 -noout -checkend 2592000 -in /etc/letsencrypt/live/ffmuc-cloudflare/fullchain.pem
    - require:
      - pip: certbot-venv-cloudflare-plugin
      - file: dns_cloudflare_credentials
      {% if "webserver-external" in role %}
      - file: /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh
      {% endif %}{# if "webserver-external" in role #}

{% endif %}{# if ("webserver-external" in role or "jitsi meet" in role) and cloudflare_token #}


{% if "webserver-external" in role %}
#
# Certificate for freifunk.net domains
#

# Required for running nsupdate with certbot
bind9-utils:
  pkg.installed

update-dns.sh:
  file.managed:
    - name: /var/lib/cache/salt/update-dns.sh
    - source: salt://certs/files/update-dns.sh.jinja
    - makedirs: True
    - mode: "0700"
    - template: jinja

cleanup-dns.sh:
  file.managed:
    - name: /var/lib/cache/salt/cleanup-dns.sh
    - source: salt://certs/files/cleanup-dns.sh.jinja
    - makedirs: True
    - mode: "0700"
    - template: jinja

# Salt's acme module doesn't support any DNS plugin besides Cloudflare, not even manual. Thus use cmd.run.
# TODO add 'unless' condition which checks whether cert needs renewal.
# Expiration date is not enough, should check revocation status as well. As of 2023-06 Cerbot has no command exposed for this.
muenchen.freifunk.net-wildcard-cert:
  cmd.run:
    - name: >
        /opt/certbot-venv/bin/certbot certonly -n --agree-tos -m hilfe@ffmuc.net
        --manual --manual-auth-hook /var/lib/cache/salt/update-dns.sh --manual-cleanup-hook /var/lib/cache/salt/cleanup-dns.sh
        --preferred-challenges dns --expand
        -d "muenchen.freifunk.net" -d "*.muenchen.freifunk.net"
        -d "xn--mnchen-3ya.freifunk.net" -d "*.xn--mnchen-3ya.freifunk.net"
        -d "wertingen.freifunk.net" -d "*.wertingen.freifunk.net"
        -d "donau-ries.freifunk.net" -d "*.donau-ries.freifunk.net"
        -d "augsburg.freifunk.net" -d "*.augsburg.freifunk.net"
    - require:
        - pip: certbot-venv-packages
        - file: update-dns.sh
        - file: cleanup-dns.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh
{% endif %}{# if "webserver-external" in role #}
