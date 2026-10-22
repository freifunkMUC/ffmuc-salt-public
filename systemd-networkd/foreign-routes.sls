#
# systemd-networkd: leave routes and policy rules alone that it did not create
#
# Applied to all hosts. By default networkd removes every route/rule it does
# not manage whenever it (re)starts, e.g. the default route installed by bird
# or routes/rules of nebula, WireGuard and policy routing setups.
#
# networkd reads networkd.conf only on startup. Deliberately no restart or
# reload here (a restart is exactly what flushes the routes); the setting
# takes effect on the next networkd restart or reboot.
#

/etc/systemd/networkd.conf.d/10-ffmuc.conf:
  file.managed:
    - source: salt://systemd-networkd/files/networkd.conf.d-10-ffmuc.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: "0644"
