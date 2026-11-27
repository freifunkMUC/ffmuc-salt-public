# fastd is long gone from the gateways; purge the leftover package (gw06/gw07)
# and its config-files state (gw04/gw05). /etc/fastd (old keys) stays.
fastd-service-dead:
  service.dead:
    - name: fastd
    - enable: false

fastd:
  pkg.purged:
    - require:
      - service: fastd-service-dead
