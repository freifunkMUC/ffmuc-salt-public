{% if 'vlan3' in grains['hwaddr_interfaces'] or 'guardian' in grains.id or 'jvb' in grains.id %}
fail2ban-pkg:
  pkg.latest:
    - name: fail2ban

{% if 'guardian' in grains.id %}
# Debian 13 defaults to banaction=nftables, the guardians have iptables only
fail2ban-banaction:
  file.managed:
    - name: /etc/fail2ban/jail.d/zz-banaction.local
    - contents: |
        [DEFAULT]
        banaction = iptables-multiport
        banaction_allports = iptables-allports
    - mode: '0644'
    - require:
      - pkg: fail2ban-pkg
    - watch_in:
      - service: fail2ban-service
{% endif %}

fail2ban-service:
  service.running:
    - name: fail2ban
    - enable: true
    # restart, not reload: a reload with a changed banaction drops the jail's actions
    - require:
      - pkg: fail2ban-pkg
{% endif %}
