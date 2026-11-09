{#- salt://rustic/files/rustic* are x86_64 builds; arm64 (guardians) takes the upstream release #}
{%- if 'backup' in salt['pillar.get']('netbox:tag_list', []) and grains.osarch in ['amd64', 'arm64'] -%}

{% set rustic_version = "v0.11.4" %}
{% set rustic_version = "nightly" %}
{%- if grains.osarch == 'arm64' %}
{%- set rustic_release = "v0.11.4" %}
rustic-release:
  archive.extracted:
    - name: /usr/local/lib/rustic-{{ rustic_release }}
    - source: https://github.com/rustic-rs/rustic/releases/download/{{ rustic_release }}/rustic-{{ rustic_release }}-aarch64-unknown-linux-musl.tar.gz
    - source_hash: sha256=35ccd40ff565b9760245dd391f9fef04c46778ce5e073d833288abe2e5eabd20
    - enforce_toplevel: False
    - user: root
    - group: root

install_rustic:
  file.symlink:
    - name: /usr/local/bin/rustic
    - target: /usr/local/lib/rustic-{{ rustic_release }}/rustic
    - force: True
    - require:
      - archive: rustic-release

# 1.8 GB RAM and bird on the same Pi: an OOM kill takes rustic
/etc/systemd/system/ffmuc-rustic-backup.service.d/memory.conf:
  file.managed:
    - makedirs: True
    - contents: |
        [Service]
        MemoryMax=1200M
        OOMScoreAdjust=1000
    - onchanges_in:
      - cmd: systemd-reload-ffmuc-backup
{%- else %}
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
    - source:
        - salt://rustic/files/rustic-{{ rustic_version }}
        - salt://rustic/files/rustic
    - mode: "0755"
{%- endif %}

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

{% if salt['config.get']('netbox:config_context:backup:no_cache', False) %}
# the cache holds the index of the whole shared repository (several GB)
rustic-cache-absent:
  file.absent:
    - name: /var/cache/rustic
{% endif %}

backup-script:
  file.absent:
    - name: /usr/local/sbin/rustic-backup.sh

{#- backup.dump_commands: {name: command} writes each command's output to /var/lib/ffmuc-dumps/<name> as rustic
    run-before hook with on-failure = "warn" (a local file instead of stdin_commands: rustic reads stdin on one core,
    which was too slow for Mastodon). Icinga service ffmuc_dumps checks their age. #}
/usr/local/sbin/ffmuc-rustic-dumps.sh:
{%- if salt['config.get']('netbox:config_context:backup:dump_commands', {}) %}
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-dumps.sh.jinja
    - template: jinja
    - mode: "0700"
{%- else %}
  file.absent
{%- endif %}

/etc/systemd/system/ffmuc-rustic-backup.service:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup.service
    - require:
      - file: backup-config
      - file: /usr/local/sbin/ffmuc-rustic-dumps.sh

# Icinga check_ffmuc_rustic reads the mtime; seeded once so a fresh host does not alert before its first run
ffmuc-rustic-last-success-seed:
  cmd.run:
    - name: touch /var/lib/ffmuc-rustic-last-success
    - creates: /var/lib/ffmuc-rustic-last-success

/etc/systemd/system/ffmuc-rustic-backup.timer:
  file.managed:
    - source: salt://rustic/files/ffmuc-rustic-backup.timer
    - require:
      - file: backup-config

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
