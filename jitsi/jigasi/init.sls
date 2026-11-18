{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.jigasi.enabled %}

include:
  - jitsi.base

jigasi:
  pkg.installed:
    - version: {{ jitsi.jigasi.version }}
    - hold: True
    - update_holds: True
    - require:
      - pkgrepo: jitsi-repo
      - cmd: jitsi-java17
  service.running:
    - enable: True
    - require:
      - file: /etc/jitsi/jigasi/config
      - file: /etc/jitsi/jigasi/sip-communicator.properties
    - watch:
      - file: /etc/jitsi/jigasi/config
      - file: /etc/jitsi/jigasi/sip-communicator.properties
      - file: /etc/systemd/system/jigasi.service.d/after-asterisk.conf

/etc/systemd/system/jigasi.service.d/after-asterisk.conf:
  file.managed:
    - makedirs: True
    - contents: |
        # Managed by Salt
        [Unit]
        After=asterisk.service
        Wants=asterisk.service

systemd-reload-jigasi:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/jigasi.service.d/after-asterisk.conf

/etc/jitsi/jigasi/config:
  file.managed:
    - source: salt://jitsi/jigasi/config.jinja
    - template: jinja
    - show_changes: False

/etc/jitsi/jigasi/sip-communicator.properties:
  file.managed:
    - source: salt://jitsi/jigasi/sip-communicator.properties.jinja
    - template: jinja
    - show_changes: False
{%- if jitsi.transcription.enabled and jitsi.transcription.save_transcripts %}

/var/lib/jigasi/transcripts:
  file.directory:
    - user: jigasi
    - makedirs: True
    - require:
      - pkg: jigasi
    - require_in:
      - service: jigasi
{%- endif %}
{% endif %}