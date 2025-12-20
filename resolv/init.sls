#
# Manage /etc/resolv.conf
#

{% set nameservers = salt['pillar.get']('netbox:config_context:nameservers', ['1.1.1.1', '8.8.8.8']) %}
{% set search_domains = salt['pillar.get']('netbox:config_context:search_domains', ['ffmuc.net']) %}

# Disable systemd-resolved to prevent conflicts with static resolv.conf
systemd-resolved:
  service.dead:
    - enable: False

/etc/resolv.conf:
  file.managed:
    - source: salt://resolv/resolv.conf
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - context:
        nameservers: {{ nameservers }}
        search_domains: {{ search_domains }}
