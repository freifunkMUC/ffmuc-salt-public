# wgkex

[wgkex](https://github.com/freifunkMUC/wgkex) hands out WireGuard gateways to the nodes.

- **Workers** run on the gateways (`nextgen-gateway` role) and are managed by this formula: git checkout of the release tag `wgkex_version` in `init.sls` (pillar `wgkex:rev` overrides it, e.g. to test a branch)
  in `/srv/wgkex/wgkex`, config `/etc/wgkex.yaml` from `wgkex.yaml.jinja`.
- **Brokers** run on docker04–07 as Komodo stacks `docker04-wgkex` … `docker07-wgkex` (`stacks/docker0X/wgkex/compose.yaml`, image
  `ghcr.io/freifunkmuc/wgkex`, same tag as the workers; Renovate bumps both in one PR). Their config is `stacks/docker0X/wgkex/wgkex.yaml` (in git, mounted read-only; no secrets, MQTT login via `WGKEX__MQTT__*` env).
  Requests reach them through haproxy (`broker_backend`), which overwrites `X-Forwarded-For`, so the brokers
  trust it from the webfrontends (`broker.trusted_proxies`).
- **MQTT** (EMQX cluster `mqtt_cluster` in the same stacks, `broker.ov.ffmuc.net:1883`): the workers log in as
  pillar `wgkex:mqtt:username`/`password` (empty: anonymous), the brokers as `wgkex-broker` with the Periphery secret
  `WGKEX_MQTT_BROKER_PASSWORD` (`WGKEX__MQTT__*` env, needs wgkex with freifunkMUC/wgkex#324), the Parker gateways
  (`parker/wgkex`, pgw01 and pgw03) also as `wgkex:mqtt` (the worker user). The master pillar file with
  `wgkex:mqtt` must target the pgws too, not only `gw0[4-7]`. The user `parker` is only for the old pgw01 pilot. EMQX rejects anonymous clients; `emqx/acl.conf` next to
  each `compose.yaml` allows each user only its own topics, everything else is denied (see MQTT users below).
- **Parker IPAM** is in the main NetBox `nb.ov.ffmuc.net` (the brokers write it, polld on the pgws reads it):
  - one /50 per site (`parker.sites.<pop>.netbox_filter.prefix` in the stack `wgkex.yaml`), status `container`,
    no tag. It must exist exactly once (no copy in another VRF), or the broker logs
    "Could not uniquely identify parent IPv6 prefix".
  - the tag `node-prefix` must exist. The broker makes the node /63s in the /50 with this tag. A reserved /63
    has the description `{"reserved_by": "<broker_id>", "created_by": "wgkex"}`, an assigned /63 has the
    public key of the node. Do not make or change them by hand.
  - tokens: the brokers use the Periphery secret `WGKEX_PARKER_NETBOX_TOKEN` (`ipam.prefix` view, add,
    change, delete; `extras.tag` view). polld uses the NetBox context key `parker.polld.netbox_token`
    (`ipam.prefix` view).
- Metrics: telegraf scrapes the workers on `127.0.0.1:9101` and the brokers on `127.0.0.1:5000` (measurement
  `prometheus`, tag `wgkex_role`). haproxy denies `/metrics` publicly.

## Updating

Brokers publish v2 keys only to the chosen worker (`wireguard/{domain}/{worker}`). Old workers only listen on
`wireguard/{domain}/all`, so **update the workers first**, then the brokers:

```sh
salt 'gw0*' state.apply wgkex                     # or wait for the 18:00 highstate; checks out the pinned tag, restarts the worker
# then deploy the stacks docker04-wgkex … docker07-wgkex in Komodo, one at a time
```

## Planned gateway reboot (drain)

1. `salt $GW cmd.run 'touch /run/wgkex/drain'`. The worker logs `Worker is draining` and reports status 2. The brokers
   stop assigning new nodes to it and ask it to evict 10 % of its peers per minute.
2. Wait until its connected peers are close to 0 (about 20 min for 90 %), see the wgkex dashboard on stats.ffmuc.net.
3. Reboot. `/run` is cleared, so the worker comes back undrained; rebalancing moves peers back after 10 minutes.

Cancel a drain without rebooting with `rm /run/wgkex/drain`.

## MQTT users

EMQX creates the users `wgkex-broker`, `wgkex-worker` and `parker` from the Periphery secrets
`WGKEX_MQTT_{BROKER,WORKER,PARKER}_PASSWORD` (hex only, `openssl rand -hex 24`; the gateways' pillar
`wgkex:mqtt:password` is the worker password). It imports them only while its user table is empty, and the table
lives in the anonymous volume `/opt/emqx/data` that survives restarts and redeploys. To change a password:

1. Set the new value in the pillar, `state.apply komodo-periphery` on docker04–07 (and the gateways' highstate).
2. Stop the four `mqtt_cluster` containers together (`docker compose down` of the stacks, without `-v` the old
   volumes stay as orphans), then deploy the four stacks. The new containers start with empty volumes and import the
   users. wgkex is down meanwhile, retained messages and sessions are gone; the workers republish their data within
   five minutes. Clients still using the old password are locked out until they get the new one.

Every client needs its credentials before EMQX enforces them: the broker image must read `WGKEX__MQTT__*`
(wgkex#324; v0.5.1 does not), the gateways and the pgws need the pillar from a highstate. Check on each
node that no client is anonymous: `docker exec mqtt_cluster emqx ctl clients list | grep -c 'username=undefined'`.
Denied publishes are dropped silently (`deny_action = ignore`, a disconnect would make clients reconnect in a loop);
look for them with `docker exec mqtt_cluster emqx ctl broker metrics | grep authorization`.

