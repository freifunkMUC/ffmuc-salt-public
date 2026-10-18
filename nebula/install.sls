###
# install nebula
###

{%- from "nebula/map.jinja" import nebula with context %}
{%- set arch = "arm-7" if grains.osarch == "armhf" else grains.osarch %}
{%- set deb = "/var/cache/nebula/nebula_" ~ nebula.version ~ "_" ~ grains.osarch ~ ".deb" %}

nebula-deb:
  file.managed:
    - name: {{ deb }}
    - source: https://github.com/krombel/nebula/releases/download/v{{ nebula.version }}/nebula-linux-{{ arch }}.deb
    - source_hash: sha256={{ nebula.packages[nebula.version][grains.osarch] }}
    - makedirs: True

nebula-pkg:
  pkg.installed:
    - sources:
      - nebula: {{ deb }}
    - require:
      - file: nebula-deb
