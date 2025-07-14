#
# APT
#
{% set site_slug = salt['pillar.get']("netbox:site:slug") %}

{% if grains.os == 'Ubuntu' and grains.osmajorrelease >= 24 %}
/etc/apt/sources.list.d/ubuntu.sources:
{% else %}
/etc/apt/sources.list:
{% endif %}
  file.managed:
    - source:
      - salt://apt/sources.list.{{ grains.os }}.{{ grains.oscodename }}.{{ site_slug }}
      - salt://apt/sources.list.{{ grains.os }}.{{ grains.oscodename }}

/etc/apt/sources.list.d/repo_saltstack_com_apt_debian_9_amd64_latest.list:
  file.absent

# as configured in sources.list so duplicate
/etc/apt/sources.list.d/hetzner-mirror.list:
  file.absent
/etc/apt/sources.list.d/hetzner-security-updates.list:
  file.absent

salt-repo-key:
  cmd.run:
    - name: "curl -sSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public | gpg --batch --dearmor -o /usr/share/keyrings/salt-archive-keyring.gpg"
    - creates: /usr/share/keyrings/salt-archive-keyring.gpg

salt-repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] https://packages.broadcom.com/artifactory/saltproject-deb/ stable main
    - file: /etc/apt/sources.list.d/saltstack.list
    - clean_file: True
    - require:
      - cmd: salt-repo-key

/etc/cron.d/apt:
  file.managed:
    - source: salt://apt/update_apt.cron

apt-transport-https:
  pkg.installed

python3-apt:
  pkg.installed

# Purge old stuff
/etc/apt/sources.list.d/raspi.list:
  file.absent

/etc/apt/sources.list.d/universe-factory.list:
  file.absent

/etc/apt/preferences.d/libluajit:
  file.managed:
    - contents: |
        Package: libluajit-5.1-2
        Pin: origin deb.debian.org
        Pin-Priority: 1001
