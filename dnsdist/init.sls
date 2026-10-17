#
# dnsdist
#
# systemd-resolved is disabled by 'resolv' state
#
{% if 'dnsdist' in salt['pillar.get']('netbox:tag_list', []) %}

dnsdist-repo-key:
  cmd.run:
    - name: "/usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/trusted.gpg.d/FD380FBB.asc"
    # NOTE: no 'creates' guard: PowerDNS periodically re-signs the FD380FBB key to
    # extend its expiry. Always re-fetch so an expired key (EXPKEYSIG) is refreshed.

dnsdist-repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }}] https://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-dnsdist-20 main
    - file: /etc/apt/sources.list.d/dnsdist.list
    - clean_file: True
    - require:
      - cmd: dnsdist-repo-key

{#- Pinned so upgrades are rolled out deliberately; the wildcard covers the
    distro suffix (e.g. 2.0.10-1pdns.ubuntu24.04). Override per host via the
    NetBox config context if a distro lacks this build (bullseye: 2.0.8). #}
{%- set dnsdist_version = salt['config.get']('netbox:config_context:dnsdist:version', '2.0.10-*') %}
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
    - watch:
      - file: dnsdist-service-override
      - file: /etc/dnsdist/dnsdist.conf

/etc/dnsdist/dnsdist.conf:
  file.managed:
    - source: salt://dnsdist/dnsdist.conf.j2
    - template: jinja
    - require:
        - pkg: dnsdist

/var/lib/dnsdist:
  file.directory:
    - user: _dnsdist
    - group: _dnsdist
    - require:
      - pkg: dnsdist

/var/lib/dnsdist/providerPublic.cert:
  file.managed:
    - source: salt://dnsdist/private/providerPublic.cert
    - user: 1000
    - group: 1000
    - mode: "0644"
    - require_in:
      - service: dnsdist
/var/lib/dnsdist/providerPrivate.key:
  file.managed:
    - source: salt://dnsdist/private/providerPrivate.key
    - user: 1000
    - group: 1000
    - mode: "0644"
    - require_in:
      - service: dnsdist

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

# Larger socket buffers/backlogs: with kernel defaults (208 KB) UDP bursts overflow the receive buffers
# (RcvbufErrors) of dnsdist and nebula. The defaults only apply to sockets opened after the change.
# Same values as the long-standing manual tuning on the gateways.
{%- for key, value in {
  'net.core.rmem_default': 31457280,
  'net.core.rmem_max': 33554432,
  'net.core.wmem_default': 31457280,
  'net.core.wmem_max': 33554432,
  'net.core.somaxconn': 65535,
  'net.core.netdev_max_backlog': 65536,
  'net.ipv4.tcp_rmem': '8192 87380 33554432',
  'net.ipv4.tcp_wmem': '8192 65536 33554432',
  'net.ipv4.udp_rmem_min': 16384,
  'net.ipv4.udp_wmem_min': 16384,
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
