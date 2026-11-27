# fastd is long gone from the gateways: purge the leftover package and its
# config (old tunnel keys in /etc/fastd, deleted on purpose 27.11.2026).
fastd-service-dead:
  service.dead:
    - name: fastd
    - enable: false

fastd:
  pkg.purged:
    - require:
      - service: fastd-service-dead

/etc/fastd:
  file.absent:
    - require:
      - pkg: fastd
