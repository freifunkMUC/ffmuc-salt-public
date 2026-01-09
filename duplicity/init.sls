{%- if 'backup' in salt['pillar.get']('netbox:tag_list', []) -%}

{% if 'Raspbian' not in grains.lsb_distrib_id %}
duplicity-packages:
  pkg.installed:
    - pkgs:
      - duplicity
      - gnupg
      - gnupg-agent
      - python3-pip

    - require:
      - pkgrepo: duplicity_repo

remove_old_duplicity_sources:
  file.absent:
    - names:
      - /etc/apt/sources.list.d/duplicity-team-duplicity-release-git-focal.sources
      - /etc/apt/sources.list.d/duplicity-team-ubuntu-duplicity-release-git-noble.sources
      - /etc/apt/sources.list.d/duplicity-team-duplicity-release-git-focal.sources.distUpgrade

duplicity_repo_key:
  cmd.run:
    - name: "gpg --no-default-keyring --keyring /usr/share/keyrings/duplicity-team-keyring.gpg --keyserver keyserver.ubuntu.com --recv-keys 4BC056F4C31D7D82488C3AA9EA0A88258CB19A4A"

duplicity_repo:
  pkgrepo.managed:
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/duplicity-team-keyring.gpg] https://ppa.launchpadcontent.net/duplicity-team/duplicity-release-git/ubuntu {{ grains.oscodename }} main
    - file: /etc/apt/sources.list.d/duplicity.list
    - clean_file: True
    - require:
      - cmd: duplicity_repo_key

duplicity_repo_src:
  pkgrepo.managed:
    - name: deb-src [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/duplicity-team-keyring.gpg] https://ppa.launchpadcontent.net/duplicity-team/duplicity-release-git/ubuntu {{ grains.oscodename }} main
    - file: /etc/apt/sources.list.d/duplicity.list
    - clean_file: True
    - require:
      - cmd: duplicity_repo_key

b2sdk:
  pip.installed:
    - pip_bin: /usr/bin/pip3  # Required with Salt Onedir packaging, otherwise dependency is installed into Salt's custom Python environment
    - require:
      - pkg: duplicity-packages
{% endif %}

backup-script:
  file.managed:
    - name: /usr/local/sbin/backup.sh
    - source: salt://duplicity/files/backup.sh.jinja2
    - mode: "0750"
    - template: jinja

/etc/systemd/system/ffmuc-backup.service:
  file.managed:
    - source: salt://duplicity/files/ffmuc-backup.service

/etc/systemd/system/ffmuc-backup.timer:
  file.managed:
    - source: salt://duplicity/files/ffmuc-backup.timer

systemd-reload-ffmuc-backup:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-backup.service
      - file: /etc/systemd/system/ffmuc-backup.timer

ffmuc-backup-timer-enable:
  service.enabled:
    - name: ffmuc-backup.timer
    - require:
      - file: /etc/systemd/system/ffmuc-backup.timer
    - full_restart: True
    - onchanges:
      - file: /etc/systemd/system/ffmuc-backup.timer

{% endif %}{# if backup in tags #}
