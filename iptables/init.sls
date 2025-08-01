{% set role = salt['pillar.get']('netbox:role:name') %}

iptables_pkgs:
  pkg.installed:
    - names:
      - iptables-persistent
      - netfilter-persistent

{% if role in ('nextgen-gateway', 'guardian', 'parker-gateway') %}

netfilter_service:
  service.enabled:
    - name: netfilter-persistent
    - require:
      - pkg: iptables_pkgs

# The systemd service does not support reload, and restart would remove all rules for a moment
netfilter_reload:
  cmd.run:
    - name: netfilter-persistent start
    - require:
      - pkg: iptables_pkgs
    - onchanges:
      - file: /etc/iptables/rules.v4
      - file: /etc/iptables/rules.v6

{# Gather general information #}
{% set own_location = salt['pillar.get']('netbox:site:name') %}

{% if salt['grains.get']('ip4_interfaces:vlan3:0') %}
  {% set nat_ip = salt['grains.get']('ip4_interfaces:vlan3:0') %}
{% else %}
  {% set nat_ip = salt['grains.get']('ip4_interfaces:dummy0:0') %}
{% endif %}

{% set uplink_iface = salt['pillar.get']('netbox:config_context:network:uplink_vlan:interface') %}


/etc/iptables/rules.v4:
  file.managed:
    - source: salt://iptables/files/{{ role }}_rules.v4.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - backup: '.bak'
    - context:
        uplink_iface: {{ uplink_iface }}
        nat_ip: {{ nat_ip }}
        own_location: {{ own_location }}
    - require:
      - pkg: iptables_pkgs

/etc/iptables/rules.v6:
  file.managed:
    - source: salt://iptables/files/{{ role }}_rules.v6.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - backup: '.bak'
    - context:
        uplink_iface: {{ uplink_iface }}
        nat_ip: {{ nat_ip }}
        own_location: {{ own_location }}
    - require:
      - pkg: iptables_pkgs
{% endif %}{# if role #}
