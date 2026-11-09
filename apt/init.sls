#
# APT
#
{% set site_slug = salt['pillar.get']("netbox:site:slug") %}

{% if (grains.os == 'Ubuntu' and grains.osmajorrelease >= 24) or (grains.os == 'Debian' and grains.osmajorrelease >= 13) %}
/etc/apt/sources.list.d/{{ grains.os|lower }}.sources:
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

{%- if grains.os == 'Raspbian' %}
# Broadcom builds no armhf packages, the guardians run salt from a venv
/etc/apt/sources.list.d/saltstack.list:
  file.absent
/etc/apt/sources.list.d/salt.sources:
  file.absent
{%- else %}
salt-repo-key:
  cmd.run:
    - name: "curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public | gpg --batch --yes --dearmor -o /usr/share/keyrings/salt-archive-keyring.gpg.tmp && mv /usr/share/keyrings/salt-archive-keyring.gpg.tmp /usr/share/keyrings/salt-archive-keyring.gpg"
    - creates: /usr/share/keyrings/salt-archive-keyring.gpg

salt-repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] https://packages.broadcom.com/artifactory/saltproject-deb/ stable main
    - file: /etc/apt/sources.list.d/saltstack.list
    - clean_file: True
    - require:
      - cmd: salt-repo-key
{%- endif %}

/etc/cron.d/apt:
  file.managed:
    - source: salt://apt/update_apt.cron

apt-transport-https:
  pkg.installed

python3-apt:
  pkg.installed

{%- if grains.os == 'Raspbian' %}
# kernel, firmware and bootloader of the Raspberry Pi
/etc/apt/sources.list.d/raspi.list:
  file.managed:
    - contents: deb http://archive.raspberrypi.org/debian/ {{ grains.oscodename }} main
{%- else %}
# Purge old stuff
/etc/apt/sources.list.d/raspi.list:
  file.absent
{%- if salt['pillar.get']('netbox:role:name') == 'guardian' %}
# guardians on Debian: only the bootloader and its tools from the Raspberry Pi repo, kernel and firmware come from Debian
# (key from raspberrypi-archive-keyring 2025.1+rpt1, CF8A1AF502A2AA2D763BAE7E82B129927FA3303E, accepted by sqv)
/etc/apt/keyrings/raspberrypi-archive-keyring.pgp:
  file.managed:
    - source: salt://apt/raspberrypi-archive-keyring.pgp
    - makedirs: True
    - mode: "0644"

/etc/apt/sources.list.d/raspi.sources:
  file.managed:
    - contents: |
        Types: deb
        URIs: https://archive.raspberrypi.com/debian/
        Suites: {{ grains.oscodename }}
        Components: main
        Signed-By: /etc/apt/keyrings/raspberrypi-archive-keyring.pgp
    - require:
      - file: /etc/apt/keyrings/raspberrypi-archive-keyring.pgp

/etc/apt/preferences.d/raspi:
  file.managed:
    - contents: |
        Package: *
        Pin: origin archive.raspberrypi.com
        Pin-Priority: 1

        Package: rpi-eeprom raspi-utils* raspinfo libdtovl0 libgpiolib0 kms++-utils libkms++0
        Pin: origin archive.raspberrypi.com
        Pin-Priority: 500
{%- endif %}
{%- endif %}

/etc/apt/sources.list.d/universe-factory.list:
  file.absent

/etc/apt/sources.list.d/salt.list:
  file.absent

/etc/apt/preferences.d/libluajit:
  file.managed:
    - contents: |
        Package: libluajit-5.1-2
        Pin: origin deb.debian.org
        Pin-Priority: 1001
