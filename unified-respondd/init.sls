#
# unified-respondd: respondd answers for nodes behind UniFi/Omada/UISP controllers
# https://github.com/freifunkMUC/unified_respondd (PyPI), in a venv in /opt/unified-respondd.
# One systemd instance per entry in pillar unified_respondd:instances:<name>; the entry is the
# whole config file (it holds controller credentials, so the pillar lives outside Git).
#
{%- set instances = salt['pillar.get']('unified_respondd:instances', {}) %}
{%- if instances %}
{# renovate: datasource=pypi depName=unified_respondd #}
{% set unified_respondd_version = '0.2.0' %}

unified-respondd-python3-venv:
  pkg.installed:
    - name: python3-venv

# Recreate the venv when the package no longer imports (e.g. Python changed by a release upgrade)
unified-respondd-venv:
  cmd.run:
    - name: python3 -m venv --clear /opt/unified-respondd
    - unless: /opt/unified-respondd/bin/python3 -c 'import unified_respondd'
    - require:
      - pkg: unified-respondd-python3-venv

unified-respondd-package:
  pip.installed:
    - name: unified_respondd == {{ unified_respondd_version }}
    - bin_env: /opt/unified-respondd/bin/pip
    - require:
      - cmd: unified-respondd-venv

/etc/systemd/system/unified-respondd@.service:
  file.managed:
    - source: salt://unified-respondd/unified-respondd@.service
    - mode: "0644"

unified-respondd-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/unified-respondd@.service

/etc/unified-respondd:
  file.directory:
    - user: root
    - group: root
    - mode: "0700"

{% for name in instances %}
# from the pillar directly, so the credentials are neither in the rendered state nor in its diff
/etc/unified-respondd/{{ name }}.yaml:
  file.serialize:
    - serializer: yaml
    - dataset_pillar: unified_respondd:instances:{{ name }}
    - user: root
    - group: root
    - mode: "0600"
    - show_changes: False
    - require:
      - file: /etc/unified-respondd

unified-respondd@{{ name }}:
  service.running:
    - enable: True
    - require:
      - cmd: unified-respondd-daemon-reload
    - watch:
      - pip: unified-respondd-package
      - file: /etc/systemd/system/unified-respondd@.service
      - file: /etc/unified-respondd/{{ name }}.yaml
{% endfor %}
{%- endif %}
