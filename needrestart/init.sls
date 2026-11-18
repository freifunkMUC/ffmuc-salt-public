#
# needrestart
#
# unattended-upgrades runs needrestart after every library upgrade, and on
# Ubuntu it restarts affected services automatically. That hits users:
# a restart of systemd-networkd flushes routes installed by bird/nebula,
# a restart of prosody drops every conference on that shard.
#

/etc/needrestart/conf.d/50-ffmuc.conf:
  file.managed:
    - source: salt://needrestart/50-ffmuc.conf.jinja
    - template: jinja
    - makedirs: True
    - user: root
    - group: root
    - mode: "0644"
