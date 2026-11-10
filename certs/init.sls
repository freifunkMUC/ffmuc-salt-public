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

{#- Default to '' rather than to the same lookup again: an unset role made
    this None, and `'...' in None` aborts the render with a TypeError. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}

#
# Traefik ACME DNS update script for docker hosts and mail01 (mailserver role,
# Traefik under /opt/containers/traefik, see stacks/mail01/traefik)
#
{% if "docker" in role or "mailserver" in role %}
{% set traefik_dir = '/opt/containers/traefik' if "mailserver" in role else '/srv/docker/traefik' %}
{{ traefik_dir }}/update-dns.sh:
  file.managed:
    - source: salt://certs/files/traefik-dns-update.sh.jinja
    - template: jinja
    - mode: "0700"
{% endif %}{# if "docker" in role or "mailserver" in role #}

{% set gcore_token = salt['pillar.get']('netbox:config_context:gcore:api_token') %}
{% from "certs/ddr_cert.jinja" import ddr_responder, ddr_staging, ddr_issue, ddr_cert_name, ddr_dns_names, ddr_ips with context %}
{% set cloudflare_token = salt['config.get']('netbox:config_context:cloudflare:api_token') %}

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

# Recreate the venv when certbot no longer imports (e.g. Python changed by a release upgrade)
certbot-venv:
  cmd.run:
    - name: python3 -m venv --clear /opt/certbot-venv
    - unless: /opt/certbot-venv/bin/python3 -c 'import certbot'
    - require:
      - pkg: python3-venv

certbot-venv-packages:
  pip.installed:
    - bin_env: /opt/certbot-venv/bin/pip
    - pkgs:
      # DDR certificate ffmuc-dns needs >= 5.4: --ip-address and --preferred-profile (certs/ddr_cert.jinja)
      - certbot>={{ '5.4' if ddr_responder else '2.0.0' }}
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

{% if "webserver-external" in role and gcore_token and ddr_responder %}
#
# DDR certificate "ffmuc-dns" (RFC 9462): anycast resolver IPs + DoH/DoT/DoQ names.
# Gated by NetBox config context ddr_cert, see certs/ddr_cert.jinja.
# Names: DNS-01 (Gcore). IPs: HTTP-01, answered by haproxy on every webfrontend
# from the peers table meet/acme (haproxy/haproxy.cfg).
#
{% set acme_hook = '/var/lib/cache/salt/ffmuc-dns-acme-hook.py' %}
{% set acme_accounts = '/etc/letsencrypt/accounts' %}

ffmuc-dns-acme-hook:
  file.managed:
    - name: {{ acme_hook }}
    - source: salt://certs/files/ffmuc-dns-acme-hook.py
    - makedirs: True
    - mode: "0700"

# One ACME account per node. haproxy needs the thumbprint of every account to answer HTTP-01.
{% for acme_server, server_flag in [('acme-v02.api.letsencrypt.org', ''), ('acme-staging-v02.api.letsencrypt.org', '--staging')] %}
ffmuc-dns-acme-account-{{ acme_server.split('.')[0] }}:
  cmd.run:
    - name: /opt/certbot-venv/bin/certbot register -n --agree-tos -m hilfe@ffmuc.net {{ server_flag }}
    - unless: ls {{ acme_accounts }}/{{ acme_server }}/directory/*/private_key.json
    - require:
      - pip: certbot-venv-packages
{% endfor %}

# Publish the public account thumbprints (RFC 7638) in the Salt mine as "acme_thumbprints".
# Only when they changed, so a highstate stays clean.
{% set thumbprints_now = salt['ffmuc_acme.account_thumbprints']() if 'ffmuc_acme.account_thumbprints' in salt else [] %}
{% set thumbprints_mine = (salt['mine.get'](grains['id'], 'acme_thumbprints', tgt_type='glob') or {}).get(grains['id']) %}
ffmuc-dns-acme-thumbprints:
  module.run:
    - mine.send:
      - acme_thumbprints
      - mine_function: ffmuc_acme.account_thumbprints
    - require:
      - cmd: ffmuc-dns-acme-account-acme-v02
      - cmd: ffmuc-dns-acme-account-acme-staging-v02
{% if thumbprints_now and thumbprints_mine == thumbprints_now %}
    - onchanges:
      - cmd: ffmuc-dns-acme-account-acme-v02
      - cmd: ffmuc-dns-acme-account-acme-staging-v02
{% endif %}

# dnsdist runs as _dnsdist (group ssl-cert) and must read the key of a new lineage
/etc/letsencrypt/renewal-hooks/deploy/00-ffmuc-dns-permissions.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        case "$RENEWED_LINEAGE" in
          */{{ ddr_cert_name }}|*/{{ ddr_cert_name }}-staging)
            key="$(readlink -f "$RENEWED_LINEAGE/privkey.pem")"
            chgrp ssl-cert "$key" && chmod 0640 "$key"
            ;;
        esac
    - mode: "0750"
    - makedirs: True

{% set ddr_lineages = [] %}
{% if ddr_staging %}{% do ddr_lineages.append((ddr_cert_name ~ '-staging', '--staging')) %}{% endif %}
{% if ddr_issue %}{% do ddr_lineages.append((ddr_cert_name, '')) %}{% endif %}
{% for lineage, server_flag in ddr_lineages %}
# Let's Encrypt "shortlived" profile (6 days, required for IP addresses). certbot renews
# certificates with less than 10 days lifetime when half of it is left (or earlier via ARI).
{{ lineage }}-cert:
  cmd.run:
    - name: >
        /opt/certbot-venv/bin/certbot certonly -n --agree-tos -m hilfe@ffmuc.net {{ server_flag }}
        --cert-name {{ lineage }}
        --manual
        --manual-auth-hook "{{ acme_hook }} auth"
        --manual-cleanup-hook "{{ acme_hook }} cleanup"
        --preferred-challenges dns,http
        --preferred-profile shortlived
        {%- for name in ddr_dns_names %}
        -d "{{ name }}"
        {%- endfor %}
        {%- for ip in ddr_ips %}
        --ip-address "{{ ip }}"
        {%- endfor %}
    # Valid for more than 2 days and SANs match (an address change triggers a new certificate)
    - unless: >
        /opt/certbot-venv/bin/python3 {{ acme_hook }} covers /etc/letsencrypt/live/{{ lineage }}/fullchain.pem 172800
        {{ (ddr_dns_names + ddr_ips) | join(' ') }}
    - require:
      - file: ffmuc-dns-acme-hook
      - file: dns_gcore_credentials
      - pip: certbot-venv-gcore-plugin
      - cmd: ffmuc-wildcard-cert
      - module: ffmuc-dns-acme-thumbprints
      - file: /etc/letsencrypt/renewal-hooks/deploy/00-ffmuc-dns-permissions.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh
      - file: /etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh

# certbot runs the deploy hooks only on renewal, so fix the key permissions after the first issuance
{{ lineage }}-key-permissions:
  cmd.run:
    - name: /etc/letsencrypt/renewal-hooks/deploy/00-ffmuc-dns-permissions.sh
    - env:
      - RENEWED_LINEAGE: /etc/letsencrypt/live/{{ lineage }}
    - onchanges:
      - cmd: {{ lineage }}-cert
{% endfor %}

{% if not ddr_staging %}
{{ ddr_cert_name }}-staging-cert-absent:
  cmd.run:
    - name: /opt/certbot-venv/bin/certbot delete -n --cert-name {{ ddr_cert_name }}-staging
    - onlyif: test -e /etc/letsencrypt/renewal/{{ ddr_cert_name }}-staging.conf
{% endif %}
{% endif %}{# if "webserver-external" in role and gcore_token and ddr_responder #}


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
        -d "ffmeet.net" -d "*.ffmeet.net"
        -d "ffmeet.de" -d "*.ffmeet.de"
        -d "klassenkonferenz.de" -d "*.klassenkonferenz.de"
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
        openssl x509 -noout -checkend 2592000 -in /etc/letsencrypt/live/ffmuc-cloudflare/fullchain.pem &&
        openssl x509 -noout -ext subjectAltName -in /etc/letsencrypt/live/ffmuc-cloudflare/fullchain.pem | grep -q 'DNS:\*.klassenkonferenz.de'
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
    - unless: >
        test -f /etc/letsencrypt/live/muenchen.freifunk.net/fullchain.pem &&
        openssl x509 -noout -checkend 2592000 -in /etc/letsencrypt/live/muenchen.freifunk.net/fullchain.pem
    - require:
        - pip: certbot-venv-packages
        - file: update-dns.sh
        - file: cleanup-dns.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh
        - file: /etc/letsencrypt/renewal-hooks/deploy/03-reload-haproxy.sh
{% endif %}{# if "webserver-external" in role #}
