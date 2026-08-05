{%- if 'backup' in salt['pillar.get']('netbox:tag_list', []) -%}

{% set rustic_version = "v0.11.3" %}
install_rustic:
  #archive.extracted:
  #  - name: /tmp/rustic
  #  - source: https://github.com/rustic-rs/rustic/releases/download/{{ rustic_version }}/rustic-{{ rustic_version }}-x86_64-unknown-linux-musl.tar.gz
  #  - source_hash: "https://github.com/rustic-rs/rustic/releases/download/{{ rustic_version }}/rustic-{{ rustic_version }}-x86_64-unknown-linux-musl.tar.gz.sha256"
  #  - cleanup: true
  #  - creates: /usr/local/bin/rustic
  #  - enforce_toplevel: false
  #  - keep_source: false
  #cmd.run:
  #  - name: mv /tmp/rustic/rustic /usr/local/bin/rustic && chmod +x /usr/local/bin/rustic
  #  - unless: test -f /usr/local/bin/rustic
  file.managed:
    - name: /usr/local/bin/rustic
    - source: salt://rustic/files/rustic
    - mode: "0755"

backup-config:
  file.managed:
    - name: /root/.config/rustic/rustic.toml
    - source: salt://rustic/files/rustic.toml.j2
    - makedirs: True
    - mode: "0600"
    - template: jinja
    - require:
      #- archive: install_rustic
      #- cmd: install_rustic
      - file: install_rustic

backup-script:
  file.managed:
    - name: /usr/local/sbin/rustic-backup.sh
    - source: salt://rustic/files/rustic-backup.sh.j2
    - mode: "0750"
    - template: jinja
    - require:
      - file: backup-config

/etc/systemd/system/ffmuc-rustic-backup.service:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup.service
    - require:
      - file: backup-script

/etc/systemd/system/ffmuc-rustic-backup.timer:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup.timer
    - require:
      - file: backup-script

systemd-reload-ffmuc-backup:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-rustic-backup.service
      - file: /etc/systemd/system/ffmuc-rustic-backup.timer
    - require:
      - file: /etc/systemd/system/ffmuc-rustic-backup.service
      - file: /etc/systemd/system/ffmuc-rustic-backup.timer

ffmuc-backup-timer-enable:
  service.running:
    - name: ffmuc-rustic-backup.timer
    - enable: true
    - require:
      - file: /etc/systemd/system/ffmuc-rustic-backup.timer
    - full_restart: True

{% if 'backup-cleaner' in salt['pillar.get']('netbox:tag_list', []) -%}

/etc/systemd/system/ffmuc-rustic-backup-cleaner.service:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup-cleaner.service
    - require:
      - file: backup-config
    - require_in:
      - cmd: systemd-reload-ffmuc-backup

/etc/systemd/system/ffmuc-rustic-backup-cleaner.timer:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup-cleaner.timer
    - require:
      - file: backup-config
    - require_in:
      - cmd: systemd-reload-ffmuc-backup

ffmuc-backup-cleaner-timer-enable:
  service.running:
    - name: ffmuc-rustic-backup-cleaner.timer
    - enable: true
    - require:
      - file: /etc/systemd/system/ffmuc-rustic-backup-cleaner.timer
    - full_restart: True

{% endif %}{# if backup_cleaner in tags #}
{% endif %}{# if backup in tags #}
