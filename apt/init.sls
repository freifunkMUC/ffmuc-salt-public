#
# APT
#
{% set site_slug = salt['pillar.get']("netbox:site:slug") %}
/etc/apt/sources.list:
  file.managed:
    - source:
      - salt://apt/sources.list.{{ grains.os }}.{{ grains.oscodename }}.{{ site_slug }}
      - salt://apt/sources.list.{{ grains.os }}.{{ grains.oscodename }}

/etc/apt/sources.list.d/repo_saltstack_com_apt_debian_9_amd64_latest.list:
  file.absent

salt-repo-key:
  file.managed:
    - name: /usr/share/keyrings/salt-archive-keyring.gpg
    {% if 'Ubuntu' in grains.lsb_distrib_id %}
    - source: https://repo.saltproject.io/py3/{{ grains.lsb_distrib_id | lower }}/{{ grains.osrelease }}/{{ grains.osarch }}/latest/salt-archive-keyring.gpg
    {% elif 'Raspbian' in grains.lsb_distrib_id %}
    - source: http://repo.saltproject.io/py3/debian/{{ grains.osmajorrelease }}/{{ grains.osarch }}/latest/salt-archive-keyring.gpg
    {% else %}
    - source: http://repo.saltproject.io/py3/{{ grains.lsb_distrib_id | lower }}/{{ grains.osmajorrelease }}/{{ grains.osarch }}/latest/salt-archive-keyring.gpg # noqa: 204
    {% endif %}
    - skip_verify: True

salt-repo:
  pkgrepo.managed:
    {% if 'Ubuntu' in grains.lsb_distrib_id %}
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] http://repo.saltproject.io/py3/{{ grains.lsb_distrib_id | lower }}/{{ grains.osrelease }}/{{ grains.osarch }}/latest {{ grains.oscodename }} main
    {% elif 'Raspbian' in grains.lsb_distrib_id %}
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] http://repo.saltproject.io/py3/debian/{{ grains.osmajorrelease }}/{{ grains.osarch }}/latest {{ grains.oscodename }} main
    {% else %}
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] http://repo.saltproject.io/py3/{{ grains.lsb_distrib_id | lower }}/{{ grains.osmajorrelease }}/{{ grains.osarch }}/latest {{ grains.oscodename }} main # noqa: 204
    {% endif %}
    - file: /etc/apt/sources.list.d/saltstack.list
    - clean_file: True
    - require:
      - file: salt-repo-key

/etc/cron.d/apt:
  file.managed:
    - source: salt://apt/update_apt.cron

apt-transport-https:
  pkg.installed

python-apt:
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
