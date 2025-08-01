#
# pdns-recursor
#
# systemd-resolved is disabled by 'resolv' state
#
{% if 'recursor' in salt['pillar.get']('netbox:tag_list', []) %}

pdns-repo-key:
  cmd.run:
    - name: "/usr/lib/apt/apt-helper download-file https://repo.powerdns.com/FD380FBB-pub.asc /tmp/FD380FBB-pub.asc && mv /tmp/FD380FBB-pub.asc /etc/apt/trusted.gpg.d/FD380FBB.asc"
    - creates: /etc/apt/trusted.gpg.d/FD380FBB.asc

pdns-repo:
  pkgrepo.managed:
    - name: deb [arch=amd64] http://repo.powerdns.com/{{ grains.lsb_distrib_id | lower }} {{ grains.oscodename }}-rec-52 main
    - file: /etc/apt/sources.list.d/pdns.list
    - clean_file: True
    - require:
      - cmd: pdns-repo-key

pdns-pkg:
  pkg.installed:
    - name: pdns-recursor
    - refresh: True
    - require:
      - pkgrepo: pdns-repo

/etc/powerdns/recursor.conf:
  file.managed:
    - source: salt://pdns-recursor/recursor.conf
    - template: jinja
    - require:
      - pkg: pdns-pkg

pdns-recursor:
  service.running:
    - enable: True
    - restart: True
    - require:
      - pkg: pdns-pkg
      - file: /etc/powerdns/recursor.conf
    - watch:
      - file: /etc/powerdns/recursor.conf

{% endif %}
