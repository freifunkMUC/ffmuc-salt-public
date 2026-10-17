##
# Vosk speech recognition server (alphacep/vosk-server websocket) for jigasi transcription, CPU only, no docker
##
{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.vosk.enabled %}
{%- set vosk_home = "/opt/vosk-server" %}
{%- set model_path = vosk_home ~ "/models/" ~ jitsi.vosk.model %}

vosk-dependencies:
  pkg.installed:
    - pkgs:
      - python3-venv
      - unzip
      - curl

vosk-user:
  user.present:
    - name: vosk
    - system: True
    - home: {{ vosk_home }}
    - createhome: False
    - shell: /usr/sbin/nologin

{{ vosk_home }}/models:
  file.directory:
    - makedirs: True
    - mode: "0755"

vosk-venv:
  cmd.run:
    - name: python3 -m venv {{ vosk_home }}/venv
    - creates: {{ vosk_home }}/venv/bin/python3
    - require:
      - pkg: vosk-dependencies
      - file: {{ vosk_home }}/models

vosk-pip:
  cmd.run:
    - name: "{{ vosk_home }}/venv/bin/pip install --no-cache-dir{% for pkg in jitsi.vosk.pip_packages %} '{{ pkg }}'{% endfor %}"
    - unless: "{% for pkg in jitsi.vosk.pip_packages %}{{ vosk_home }}/venv/bin/pip freeze | grep -qix '{{ pkg }}'{% if not loop.last %} && {% endif %}{% endfor %}"
    - require:
      - cmd: vosk-venv

{{ vosk_home }}/asr_server.py:
  file.managed:
    - source: {{ jitsi.vosk.server_script_url }}
    - source_hash: {{ jitsi.vosk.server_script_hash }}
    - mode: "0644"

# models are 45 MB up to several GB, downloaded only once per model name
vosk-model:
  cmd.run:
    - name: "cd {{ vosk_home }}/models && curl -fsSL -o {{ jitsi.vosk.model }}.zip {{ jitsi.vosk.model_base_url }}/{{ jitsi.vosk.model }}.zip && unzip -q {{ jitsi.vosk.model }}.zip && rm -f {{ jitsi.vosk.model }}.zip"
    - creates: {{ model_path }}
    - require:
      - pkg: vosk-dependencies
      - file: {{ vosk_home }}/models

/etc/systemd/system/vosk-server.service:
  file.managed:
    - source: salt://jitsi/vosk/files/vosk-server.service.jinja
    - template: jinja
    - context:
        vosk_home: {{ vosk_home }}
        model_path: {{ model_path }}

vosk-systemd-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/vosk-server.service

vosk-server:
  service.running:
    - enable: True
    - require:
      - user: vosk-user
      - cmd: vosk-systemd-reload
    - watch:
      - file: /etc/systemd/system/vosk-server.service
      - file: {{ vosk_home }}/asr_server.py
      - cmd: vosk-pip
      - cmd: vosk-model

{% endif %}{# if jitsi.vosk.enabled #}
