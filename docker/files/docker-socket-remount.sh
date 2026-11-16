#!/bin/sh
# Managed by Salt (docker/init.sls), run as ExecStartPost of docker.service.
# With live-restore, containers survive a dockerd restart, but restarting docker.socket (package upgrade)
# replaces /run/docker.sock and containers that bind-mount it keep the dead inode: restart those started before it.
set -u
sock=/run/docker.sock
[ -S "$sock" ] || exit 0
created=$(stat -c %Y "$sock")

docker ps -q | while read -r id; do
  info=$(docker inspect -f '{{.State.StartedAt}}{{range .Mounts}} {{.Source}}{{end}}' "$id") || continue
  case " $info " in
    *" /run/docker.sock "* | *" /var/run/docker.sock "*) ;;
    *) continue ;;
  esac
  started=$(date -d "${info%% *}" +%s) || continue
  if [ "$started" -lt "$created" ]; then
    logger -t docker-socket-remount "restarting $id: started before $sock was recreated"
    docker restart "$id" >/dev/null || logger -t docker-socket-remount "restart of $id failed"
  fi
done
