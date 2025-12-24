#
# dnsdist
#
# systemd-resolved is disabled by 'resolv' state
#
{% if 'dnsdist' in salt['pillar.get']('netbox:tag_list', []) %}

dnsdist-repo-key:
  cmd.run:
    - name: "/usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/trusted.gpg.d/FD380FBB.asc"
    - creates: /etc/apt/trusted.gpg.d/FD380FBB.asc

dnsdist-repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }}] https://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-dnsdist-20 main
    - file: /etc/apt/sources.list.d/dnsdist.list
    - clean_file: True
    - require:
      - cmd: dnsdist-repo-key

dnsdist:
  pkg.installed:
    - refresh: True
    - require:
      - pkgrepo: dnsdist-repo
  service.running:
    - enable: True
    - restart: True
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

{% endif %}{# if 'dnsdist' in tag_list #}
