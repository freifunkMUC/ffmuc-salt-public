###
# install nebula
###

{%- from "nebula/map.jinja" import nebula with context %}

# temporary via krombels repo until https://github.com/slackhq/nebula/pull/514 is merged
nebula-pkg:
  pkg.installed:
    - sources:
    {% if grains.osarch == "armhf" %}
      - nebula: https://github.com/krombel/nebula/releases/download/v{{ nebula.version }}/nebula-linux-arm-7.deb
    {% else %}
      - nebula: https://github.com/krombel/nebula/releases/download/v{{ nebula.version }}/nebula-linux-{{ grains.osarch }}.deb
    {% endif %}
