#
# Unattended Upgrades
#

unattended-upgrades:
  pkg.installed:
    - name: unattended-upgrades

# installed as a dependency on some hosts, autoremove would take it away
unattended-upgrades-manual:
  cmd.run:
    - name: apt-mark manual unattended-upgrades
    - unless: apt-mark showmanual | grep -qx unattended-upgrades
    - require:
      - pkg: unattended-upgrades

/etc/apt/apt.conf.d/20auto-upgrades:
  file.managed:
    - source: salt://unattended-upgrades/20auto-upgrades

/etc/apt/apt.conf.d/50unattended-upgrades:
  file.managed:
    - source:
       - salt://unattended-upgrades/50unattended-upgrades.{{ grains.os }}.{{ grains.oscodename }}
       - salt://unattended-upgrades/50unattended-upgrades
    - template: jinja
