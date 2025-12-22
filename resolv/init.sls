#
# Manage /etc/resolv.conf
#
# If machine runs pdns-recursor or dnsdist:
#   - Disable systemd-resolved
#   - Install static resolv.conf pointing to anycast servers
# Otherwise:
#   - Use systemd-resolved with anycast servers
#   - Create symlink to stub-resolv.conf

{% set has_recursor = salt['pillar.get']('netbox:services', []) | selectattr('name', 'equalto', 'pdns-recursor') | list | length > 0 %}
{% set has_dnsdist = 'dnsdist' in salt['pillar.get']('netbox:tag_list', []) %}
{% set use_local_resolver = has_recursor or has_dnsdist %}

{% if use_local_resolver %}
# Machine runs local DNS resolver - disable systemd-resolved and use static resolv.conf
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
    - follow_symlinks: False
    - require:
      - service: systemd-resolved

{% else %}
# Machine uses systemd-resolved
systemd-resolved:
  service.running:
    - enable: True

/etc/systemd/resolved.conf:
  file.managed:
    - source: salt://resolv/resolved.conf
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - watch_in:
      - service: systemd-resolved

/etc/resolv.conf:
  file.symlink:
    - target: /run/systemd/resolve/stub-resolv.conf
    - force: True
    - require:
      - service: systemd-resolved

{% endif %}
