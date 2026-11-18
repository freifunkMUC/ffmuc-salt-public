#
# sflowtool on the guardians: forwards sFlow (udp/6343) to the collector over Nebula.
# The binary /usr/local/bin/sflowtool is built by hand from github.com/sflow/sflowtool,
# the arguments come from the NetBox config context sflowtool:args.
#
{%- set args = salt['pillar.get']('netbox:config_context:sflowtool:args', '') %}
{%- if args %}

# sflowtool asks for 2 MB socket buffers, the default max is 360 KB
{%- for key in ['net.core.rmem_max', 'net.core.wmem_max'] %}
{{ key }}:
  sysctl.present:
    - value: 2000000
    - config: /etc/sysctl.d/30-sflowtool.conf
{%- endfor %}

/etc/default/sflowtool:
  file.managed:
    - contents: SFLOWTOOL_ARGS="{{ args }}"

/etc/systemd/system/sflowtool.service:
  file.managed:
    - source: salt://sflowtool/sflowtool.service

sflowtool:
  service.running:
    - enable: True
    - onlyif: test -x /usr/local/bin/sflowtool
    - watch:
      - file: /etc/default/sflowtool
      - file: /etc/systemd/system/sflowtool.service
      - sysctl: net.core.rmem_max
      - sysctl: net.core.wmem_max

{%- endif %}
