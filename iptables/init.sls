{% set role = salt['pillar.get']('netbox:role:name') %}
{#- Jitsi hosts: rules by host name, applied by hand (not in top.sls) #}
{% set jitsi_role = {'jvb': 'jvb', 'jicofo': 'jicofo', 'call': 'call'}.get(grains.id.split('.')[0].rstrip('0123456789'), '') if grains.id.endswith('.meet.ffmuc.net') else '' %}

iptables_pkgs:
  pkg.installed:
    - names:
      - iptables-persistent
      - netfilter-persistent

{% if role in ('nextgen-gateway', 'guardian', 'parker-gateway') or jitsi_role %}

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

{% if role == 'guardian' or jitsi_role %}
# The reload flushes the fail2ban chains; stop it before so actionstop does not log errors
fail2ban_before_netfilter_reload:
  cmd.run:
    - name: systemctl stop fail2ban
    - onlyif: systemctl is-active --quiet fail2ban
    - onchanges:
      - file: /etc/iptables/rules.v4
      - file: /etc/iptables/rules.v6
    - require_in:
      - cmd: netfilter_reload

fail2ban_after_netfilter_reload:
  cmd.run:
    - name: systemctl start fail2ban
    - onlyif: systemctl is-enabled --quiet fail2ban
    - onchanges:
      - cmd: netfilter_reload
{% endif %}

{% if jitsi_role %}
{% for family in ('v4', 'v6') %}
/etc/iptables/rules.{{ family }}:
  file.managed:
    - source: salt://iptables/files/jitsi_rules.{{ family }}.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - backup: '.bak'
    - context:
        jitsi_role: {{ jitsi_role }}
    - require:
      - pkg: iptables_pkgs
{% endfor %}
{% else %}
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
{% endif %}{# jitsi_role #}
{% endif %}{# if role #}
