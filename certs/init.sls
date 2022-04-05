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
    - name: openssl dhparam -out /etc/ssl/dhparam.pem 2048
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

{%- set role = salt['pillar.get']('netbox:role:name', salt['pillar.get']('netbox:device_role:name')) %}
{% set cloudflare_token = salt['pillar.get']('netbox:config_context:cloudflare:api_token') %}
{% if ("webserver-external" in role or "jitsi meet" in role) and cloudflare_token %}

{# old behaviour. Got disabled as for DoT it got necessary to set the preferred-chain to ISRG Root X1
   which is only possible with a more up to date version than available in ubuntu standard package repository.
certbot:
  pkg.installed

certbot-dns-cloudflare:
  pip.installed:
    - require:
      - pkg: python3-pip

New behaviour can be manually setup via

  apt install snapd
  snap install core # update core
  snap install --classic certbot
  snap set certbot trust-plugin-with-root=ok
  snap install certbot-dns-cloudflare

As snap is not possible to be managed with salt natively but should be coming
in next release proper rollout via salt is blocked on this issue:
https://github.com/saltstack/salt/issues/58132
#}

snapd:
  pkg.installed

certbot:
  pkg.removed:
    - name: certbot
  cmd.run:
    - name: snap install --classic certbot
    - creates: /snap/bin/certbot
    - require:
        - pkg: snapd

fix_permissions_for_certbot_plugin:
  cmd.run:
    - name: snap set certbot trust-plugin-with-root=ok
    - require:
       - cmd: certbot

python3-pip:
  pkg.installed

acme-client:
  pip.installed:
    - name: acme>=1.8.0
    - require:
      - pkg: python3-pip

certbot-dns-cloudflare:
  pip.removed:
    - name: certbot-dns-cloudflare
  cmd.run:
    - name: snap install certbot-dns-cloudflare
    - creates: /snap/certbot-dns-cloudflare/current/setup.py
    - require:
       - cmd: certbot
       - cmd: fix_permissions_for_certbot_plugin

dns_credentials:
  file.managed:
    - name: /var/lib/cache/salt/dns_plugin_credentials.ini
    - makedirs: True
    - contents: "dns_cloudflare_api_token = {{ cloudflare_token }}"
    - mode: "0600"

ffmuc-wildcard-cert:
  acme.cert:
  {% if "webserver-external" in role %}
    - name: ffmuc.net
    - aliases:
        - "*.ffmuc.net"
        - "*.ext.ffmuc.net"
        - "ffmeet.net"
        - "ffmuc.bayern"
        - "*.ffmuc.bayern"
        - "fnmuc.net"
        - "*.fnmuc.net"
        - "freie-netze.org"
        - "freifunk-muenchen.de"
        - "*.freifunk-muenchen.de"
        - "freifunk-muenchen.net"
        - "*.freifunk-muenchen.net"
        - "xn--freifunk-mnchen-8vb.de"
        - "*.xn--freifunk-mnchen-8vb.de"
        - "muenchen.freifunk.net"
        - "*.muenchen.freifunk.net"
        - "xn--mnchen-3ya.freifunk.net"
        - "*.xn--mnchen-3ya.freifunk.net"
        - "augsburg.freifunk.net"
        - "*.augsburg.freifunk.net"
  {% else %}{# "jitsi meet" in role #}
    - name: meet.ffmuc.net
    - aliases:
        - "ffmeet.de"
        - "*.ffmeet.de"
        - "ffmeet.net"
        - "*.ffmeet.net"
  {% endif %}
    - email: hilfe@ffmuc.net
    - dns_plugin: cloudflare
    - dns_plugin_credentials: /var/lib/cache/salt/dns_plugin_credentials.ini
    - owner: root
    - group: ssl-cert
    - mode: "0640"
    #- renew: True
    - require:
        - cmd: certbot
        - cmd: certbot-dns-cloudflare
        - pip: acme-client
        - file: dns_credentials

/etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        systemctl reload nginx
    - mode: "0750"
    - makedirs: True

{% endif %}{# if ("webserver-external" in role or "jitsi meet" in role) and cloudflare_token #}

{% if "webfrontend" in grains.id %}
/etc/letsencrypt/archive/:
  file.directory:
    - group: ssl-cert
    - mode: "0750"
/etc/letsencrypt/live/:
  file.directory:
    - group: ssl-cert
    - mode: "0750"

/etc/letsencrypt/renewal-hooks/deploy/02-reload-dnsdist-certs.sh:
  file.managed:
    - contents: |
        #!/bin/sh
        dnsdist -e "reloadAllCertificates()"
    - mode: "0750"
    - makedirs: True
{% endif %}
