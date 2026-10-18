# wgkex

[wgkex](https://github.com/freifunkMUC/wgkex) hands out WireGuard gateways to the nodes.

- **Workers** run on the gateways (`nextgen-gateway` role) and are managed by this formula: git checkout of `main`
  in `/srv/wgkex/wgkex`, config `/etc/wgkex.yaml` from `wgkex.yaml.jinja`.
- **Brokers** run on docker04–07 from the docker compose project in `/srv/docker/wgkex` (image
  `ghcr.io/freifunkmuc/wgkex:main`). Their config `/srv/docker/wgkex/config/broker/wgkex.yaml` is **not** managed by
  Salt. Requests reach them through haproxy (`broker_backend`), which overwrites `X-Forwarded-For`, so the brokers
  trust it from the webfrontends (`broker.trusted_proxies`).
- Metrics: telegraf scrapes the workers on `127.0.0.1:9101` and the brokers on `127.0.0.1:5000` (measurement
  `prometheus`, tag `wgkex_role`). haproxy denies `/metrics` publicly.

## Updating

Brokers publish v2 keys only to the chosen worker (`wireguard/{domain}/{worker}`). Old workers only listen on
`wireguard/{domain}/all`, so **update the workers first**, then the brokers:

```sh
salt 'gw0*' state.apply wgkex                     # pulls main and restarts the worker
salt 'docker0[4-7]*' cmd.run 'cd /srv/docker/wgkex && docker compose pull broker && docker compose up -d broker'
```

## Planned gateway reboot (drain)

1. `salt $GW cmd.run 'touch /run/wgkex/drain'`. The worker logs `Worker is draining` and reports status 2. The brokers
   stop assigning new nodes to it and ask it to evict 10 % of its peers per minute.
2. Wait until its connected peers are close to 0 (about 20 min for 90 %), see the wgkex dashboard on stats.ffmuc.net.
3. Reboot. `/run` is cleared, so the worker comes back undrained; rebalancing moves peers back after 10 minutes.

Cancel a drain without rebooting with `rm /run/wgkex/drain`.
