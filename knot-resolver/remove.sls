#
# knot-recursor
#

/etc/apt/sources.list.d/knot-resolver.list:
  file.absent

knot-resolver:
  pkg.removed

/etc/systemd/system/kresd@1.service.d:
  file.absent

# the former init.sls put its override on the template unit
/etc/systemd/system/kresd@.service.d:
  file.absent

/etc/systemd/system/kresd.socket.d:
  file.absent

/etc/knot-resolver:
  file.absent

# init.sls pinned www.internic.net for the root zone prefill. The address is
# stale (www.internic.net has moved) and may stop serving the root zone at any
# time; pdns-recursor fetches it from there.
internic-host:
  host.absent:
    - ip:
      - 192.0.32.9
      - 2620:0:2d0:200::9
    - name: www.internic.net
