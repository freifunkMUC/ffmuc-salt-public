{#- Weekly Trivy scan (weekday and hour per host from the minion ID, see the timer) of the images of running containers (docker hosts).
    Opt in per host with the NetBox config context trivy: {enabled: true}; off by default.
    Summary in /var/lib/ffmuc-trivy/report.json, checked by the Icinga service ffmuc_trivy. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}
{%- set enabled = salt['config.get']('netbox:config_context:trivy:enabled', False) %}
{%- set arch = {'amd64': '64bit', 'arm64': 'ARM64'}.get(grains.osarch) %}

{%- if enabled and 'docker' in role and arch %}
{#- renovate: datasource=github-releases depName=aquasecurity/trivy extractVersion=^v(?<version>.+)$ #}
{%- set trivy_version = "0.76.2" %}

trivy-release:
  archive.extracted:
    - name: /usr/local/lib/trivy-{{ trivy_version }}
    - source: https://github.com/aquasecurity/trivy/releases/download/v{{ trivy_version }}/trivy_{{ trivy_version }}_Linux-{{ arch }}.tar.gz
    - source_hash: https://github.com/aquasecurity/trivy/releases/download/v{{ trivy_version }}/trivy_{{ trivy_version }}_checksums.txt
    - enforce_toplevel: False
    - if_missing: /usr/local/lib/trivy-{{ trivy_version }}/trivy
    - user: root
    - group: root

trivy-binary:
  file.symlink:
    - name: /usr/local/bin/trivy
    - target: /usr/local/lib/trivy-{{ trivy_version }}/trivy
    - force: True
    - require:
      - archive: trivy-release

trivy-jq:
  pkg.installed:
    - name: jq

/usr/local/sbin/ffmuc-trivy-scan.sh:
  file.managed:
    - source: salt://trivy/files/ffmuc-trivy-scan.sh
    - mode: "0700"

/var/lib/ffmuc-trivy:
  file.directory:
    - mode: "0755"

# Icinga check_ffmuc_trivy: only runs with this file; its mtime is the grace period of a fresh host
/var/lib/ffmuc-trivy/.enabled:
  file.managed:
    - replace: False
    - mode: "0644"
    - require:
      - file: /var/lib/ffmuc-trivy

/etc/systemd/system/ffmuc-trivy-scan.service:
  file.managed:
    - source: salt://trivy/files/ffmuc-trivy-scan.service
    - require:
      - file: /usr/local/sbin/ffmuc-trivy-scan.sh
      - file: trivy-binary
      - pkg: trivy-jq

/etc/systemd/system/ffmuc-trivy-scan.timer:
  file.managed:
    - source: salt://trivy/files/ffmuc-trivy-scan.timer
    - template: jinja

systemd-reload-ffmuc-trivy:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-trivy-scan.service
      - file: /etc/systemd/system/ffmuc-trivy-scan.timer

ffmuc-trivy-timer-enable:
  service.running:
    - name: ffmuc-trivy-scan.timer
    - enable: true
    - require:
      - cmd: systemd-reload-ffmuc-trivy
      - file: /var/lib/ffmuc-trivy/.enabled

{%- else %}
{#- off: remove the whole setup, including the vulnerability database cache #}
ffmuc-trivy-timer-disable:
  service.dead:
    - name: ffmuc-trivy-scan.timer
    - enable: False

{%- for f in ['/etc/systemd/system/ffmuc-trivy-scan.service', '/etc/systemd/system/ffmuc-trivy-scan.timer',
              '/usr/local/sbin/ffmuc-trivy-scan.sh', '/usr/local/bin/trivy', '/var/lib/ffmuc-trivy',
              '/var/cache/ffmuc-trivy'] %}
{{ f }}:
  file.absent:
    - require:
      - service: ffmuc-trivy-timer-disable
{%- endfor %}

ffmuc-trivy-releases-absent:
  cmd.run:
    - name: rm -rf /usr/local/lib/trivy-*
    - onlyif: ls -d /usr/local/lib/trivy-* 2>/dev/null
    - require:
      - service: ffmuc-trivy-timer-disable
{%- endif %}
