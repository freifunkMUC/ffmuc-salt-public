#
# Bind name server
#

bind9:
  pkg.installed:
    - name: bind9
  service.running:
    - enable: True
    - reload: True

dns_pkgs:
  pkg.installed:
    - pkgs:
      - dnsutils
      - bind9-dnsutils

dnspython:
  pip.installed:  # Install into Salt's Python environment
    - reload_modules: True

# Reload command
rndc-reload:
  cmd.run:
    - name: /usr/sbin/rndc reload
