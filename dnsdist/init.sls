#
# dnsdist
#
# systemd-resolved is disabled by 'resolv' state
#
{% if 'dnsdist' in salt['pillar.get']('netbox:tag_list', []) %}

include:
  - sysctl.buffers

dnsdist-repo-key:
  cmd.run:
    - name: "mkdir -p /etc/apt/keyrings && /usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/keyrings/powerdns.asc"
    # NOTE: no 'creates' guard: PowerDNS periodically re-signs the FD380FBB key to
    # extend its expiry. Always re-fetch so an expired key (EXPKEYSIG) is refreshed.

dnsdist-repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }} signed-by=/etc/apt/keyrings/powerdns.asc] https://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-dnsdist-21 main
    - file: /etc/apt/sources.list.d/dnsdist.list
    - clean_file: True
    - require:
      - cmd: dnsdist-repo-key

{#- Old global trust of the key (apt-key era); the repo uses signed-by now #}
dnsdist-repo-legacy-key:
  file.absent:
    - name: /etc/apt/trusted.gpg.d/FD380FBB.asc
    - require:
      - pkgrepo: dnsdist-repo

{#- repo.powerdns.com only serves the latest build: bump on each release; an override has to be a 2.1 build #}
{%- set pdns_suffix = '1pdns.' ~ (grains.os | lower) ~ (grains.osrelease if grains.os == 'Ubuntu' else grains.osmajorrelease | string) %}
{%- set dnsdist_version = salt['config.get']('netbox:config_context:dnsdist:version', '2.1.3-' ~ pdns_suffix) %}
dnsdist:
  pkg.installed:
    - version: '{{ dnsdist_version }}'
    - refresh: True
    - require:
      - pkgrepo: dnsdist-repo
  service.running:
    - enable: True
    - require:
      - file: /etc/dnsdist/dnsdist.conf
      - file: /var/lib/dnsdist
      - file: dnsdist-service-override
      - sls: sysctl.buffers
    - watch:
      - file: dnsdist-service-override
      - file: /etc/dnsdist/dnsdist.conf

/etc/dnsdist/dnsdist.conf:
  file.managed:
    - source: salt://dnsdist/dnsdist.conf.j2
    - template: jinja
    - show_changes: False
    - require:
        - pkg: dnsdist

/var/lib/dnsdist:
  file.directory:
    - user: _dnsdist
    - group: _dnsdist
    - require:
      - pkg: dnsdist

{#- Temporary: the provider key is no longer on the hosts. Remove after all dnsdist hosts have applied this. #}
{%- for old in ['providerPrivate.key', 'providerPublic.cert'] %}
dnsdist-old-{{ old }}:
  file.absent:
    - name: /var/lib/dnsdist/{{ old }}
{%- endfor %}

{%- if 'webfrontend' in grains.id %}
{#-
  DNSCrypt resolver certificates: generated offline (dnsdist/dnscrypt-certs.sh, signed with the provider
  key, which stays off all hosts) and identical on every webfrontend, because clients reach any node
  behind the anycast address. Pillar netbox:config_context:dnsdist:dnscrypt_certs maps a name to
  cert and key (base64). Never generated on the host; the state fails if the pillar is missing.
  Rotation (12-month sets, serial rises): ~1 month before the old set expires generate a new set and
  add it, apply; after the old one has expired remove it, apply. Clients (dnscrypt-proxy
  refresh 4 h) pick the highest valid serial; the provider key and stamps stay unchanged.
#}
{%- set dnscrypt_certs = salt['pillar.get']('netbox:config_context:dnsdist:dnscrypt_certs', {}) %}
{%- if not dnscrypt_certs %}
dnsdist-dnscrypt-certs-missing:
  test.fail_without_changes:
    - name: netbox:config_context:dnsdist:dnscrypt_certs is missing, refusing to touch DNSCrypt
    - require_in:
      - service: dnsdist
{%- else %}
dnsdist-dnscrypt-dir:
  file.directory:
    - name: /var/lib/dnsdist/dnscrypt
    - user: root
    - group: _dnsdist
    - mode: "0750"
    - require:
      - file: /var/lib/dnsdist
    - require_in:
      - service: dnsdist
{%- for name in dnscrypt_certs | sort %}
{%- for ext in ['cert', 'key'] %}
dnsdist-dnscrypt-{{ name }}-{{ ext }}:
  file.decode:
    - name: /var/lib/dnsdist/dnscrypt/{{ name }}.{{ ext }}
    - contents_pillar: netbox:config_context:dnsdist:dnscrypt_certs:{{ name }}:{{ ext }}
    - encoding_type: base64
    - require:
      - file: dnsdist-dnscrypt-dir
    - watch_in:
      - service: dnsdist
dnsdist-dnscrypt-{{ name }}-{{ ext }}-perms:
  file.managed:
    - name: /var/lib/dnsdist/dnscrypt/{{ name }}.{{ ext }}
    - replace: False
    - user: root
    - group: _dnsdist
    - mode: "0640"
    - show_changes: False
    - require:
      - file: dnsdist-dnscrypt-{{ name }}-{{ ext }}
    - require_in:
      - service: dnsdist
{%- endfor %}
{%- endfor %}
# drop files of removed certificates (states required here are kept)
dnsdist-dnscrypt-clean:
  file.directory:
    - name: /var/lib/dnsdist/dnscrypt
    - clean: True
    - require:
{%- for name in dnscrypt_certs | sort %}
{%- for ext in ['cert', 'key'] %}
      - file: dnsdist-dnscrypt-{{ name }}-{{ ext }}-perms
{%- endfor %}
{%- endfor %}
    - require_in:
      - service: dnsdist
{%- endif %}
{%- endif %}{# webfrontend #}

dnsdist-service-override:
  file.managed:
    - name: /etc/systemd/system/dnsdist.service.d/override.conf
    - source: salt://dnsdist/dnsdist.override.service
    - makedirs: True

{%- if 'webfrontend' in grains.id %}
# to allow reading ssl cert
add_dnsdist_group_ssl-cert:
  user.present:
    - name: _dnsdist
    - groups:
      - ssl-cert
{% endif %}{# if 'webfrontend' #}

# Socket buffers and netdev backlog: see sysctl.buffers (shared with the Parker gateways).
# TCP listen tuning for the DNS frontends. Same values as the long-standing manual tuning on the gateways.
{%- for key, value in {
  'net.core.somaxconn': 65535,
  'net.ipv4.tcp_rmem': '8192 87380 33554432',
  'net.ipv4.tcp_wmem': '8192 65536 33554432',
}.items() %}
dnsdist-sysctl-{{ key }}:
  sysctl.present:
    - name: {{ key }}
    - value: {{ value }}
    - config: /etc/sysctl.d/10-tuning.conf
    - require_in:
      - service: dnsdist
{%- endfor %}

{% endif %}{# if 'dnsdist' in tag_list #}
