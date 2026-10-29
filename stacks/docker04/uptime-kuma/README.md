# Uptime Kuma (docker04)

Uptime Kuma 2.x (rootless image) for FFMUC service monitoring. Admin UI only
in the Nebula overlay (`10.8.0.31:3001`); the public status page
(`status.ffmuc.net`) is a haproxy route on the web frontends (Nebula rule:
`webfrontend` to docker04:3001) that passes only `/`, `/api/entry-page`,
`/status/*`, `/assets/*`, `/api/status-page/*`, `/api/badge/*`, `/upload/*`
and the icons; everything else gets 403. In Kuma, give the status page the
domain `status.ffmuc.net` (Settings of the page), so `/` serves it.

## Host preparation (once, by hand)

`install -d -m 0750 -o 1000 -g 1000 /srv/docker/uptime-kuma/data` before the
first deploy; otherwise Docker creates it root-owned and Kuma cannot write. SQLite is not consistent
while live: back it up with `backup.dump_commands`, not by copying `kuma.db`.

## Monitors

The monitor list (30 monitors, JSON in the AutoKuma schema) is not synced yet:
monitors are created in the UI for now.

Open:

- AutoKuma sidecar (needs Kuma's login token as Periphery secret
  `UPTIME_KUMA_AUTOKUMA_TOKEN`, so first start without it)
- Notification Mattermost `noc-monitoring` (webhook URL only in Kuma's DB)
- DNS for `status.ffmuc.net` to the web frontends (after the first deploy)
- External heartbeat (Statuscake) as dead-man switch
