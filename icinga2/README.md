# icinga2 Salt formula

Icinga 2 master (`icinga-vie01`, NetBox tag `icinga2_server`) and agents. Notifications go to Mattermost
(`mattermost-notifications.py`, user `mattermost` in `users.conf.tmpl`).

## Which hosts Icinga knows

The master renders one file per host into `/etc/icinga2/zones.d/master/ffmuc-conf.d/hosts/generated/` (the
directory is cleaned, so a host that drops out disappears from Icinga):

| Source | Template | Checks |
|---|---|---|
| Minions with the NetBox tag `icinga2_client` (Salt mine `minion_tags`) | `host.conf.jinja` | Agent: everything in `services/`, run on the host (`command_endpoint`) |
| Minions with the NetBox tag `icinga2_agentless` | `host_agentless.conf.jinja` | From the master: hostalive, ping4, ssh |
| `static_hosts.yaml` (no minion, or the minion does not answer) | `host_agentless.conf.jinja` | From the master: hostalive, ping4, ssh |
| `static_hosts.yaml` with `role: turn` (turn1, turn2) | `services/turn.conf` | From the master: 3478/tcp, TLS on 443 with certificate expiry |

- The agent needs the `icinga2` state, which `top.sls` only assigns to `*.in.ffmuc.net`, a host certificate from the
  state `certs`, and a route to the master's overlay address `icinga-vie01.ov.ffmuc.net` (nebula `nebula-nodes`).
  Hosts without that (the Jitsi hosts in `nebula-meet`) get `icinga2_agentless` until they are switched (below).
- Agentless hosts have `vars.agentless = true`; every rule that runs a check on the agent has
  `ignore where host.vars.agentless`. Add that line to new rules with `command_endpoint`.
- A host in `static_hosts.yaml` is skipped once a minion of the same name has one of the two tags.
- A minion only appears after it has answered the mine (`salt-run manage.down` lists those that do not).

## Jitsi hosts (`*.meet.ffmuc.net`) as agents

The Jitsi hosts are only in `nebula-meet`. They get the `icinga2` and `certs` states from `top.sls`; `icinga2` renders
nothing until the host has the NetBox tag `icinga2_client`.

- **Direction:** the agent connects to the master (as everywhere else, the master cannot reach the agents).
  The master's Endpoint for a `*.meet.ffmuc.net` host has no `host`, the agent's API listener binds to `127.0.0.1`
  (no host firewall on these hosts), the agent's Endpoint for the master points to the NetBox config context
  `icinga2.master_address` (the `nebula-meet` address of `icinga-vie01`, default is the `nebula-nodes` name).
  Only `icinga-vie01` allows 5665/tcp in `nebula-meet`, and only from the groups `jvb`, `jicofo`, `jibri`, `jigasi`.
- **Host check:** the master pings the public address (mine `minion_external_ip`), as for agentless hosts.
- **Certificate:** the cfssl CA is not reachable from `nebula-meet`. Issue it once per host (CN = minion id, same
  request as `cfssl_certs.request_cert`) and write `/etc/ssl/certs/<id>.cert.pem` (0644 root) and
  `/etc/ssl/private/<id>.key.pem` (0440 root:ssl-cert) before the first `icinga2` run. The `certs` state then skips
  the CA while the certificate is valid for more than 30 days; renewal needs a new manual issue.
  Copy `/etc/ssl/dhparam.pem` from a host that has it before the first `certs` run (otherwise `openssl dhparam 4096`
  runs on the bridge).
- **Switch per host:** set the NetBox tag `icinga2_client` instead of `icinga2_agentless`, refresh the mine
  (`salt <id> mine.update`, on the master `salt icinga-vie01.in.ffmuc.net mine.update`), then
  `state.apply icinga2` on the host and on `icinga-vie01.in.ffmuc.net`. Order: `call01`, then one host at a time;
  `jvb16` and `jvb18` stay agentless while they are in maintenance.

## BGP and WireGuard

- `bgp_sessions` (`plugins/check_bird_bgp_sessions`): CRITICAL when a BGP protocol in bird is not Established,
  hard after about 10 minutes. Roles `webserver-external`, `nextgen-gateway`, `freifunk-transit`.
- `wireguard_handshakes` (`plugins/check_wireguard_handshakes`): CRITICAL when a peer had no handshake for 600 s,
  including peers that never had one. Role `freifunk-transit` only; the gateways' peers are wgkex nodes.
- Both run `birdc show protocols` / `wg show all latest-handshakes` through sudo (`icinga2.sudoers`).
- Sessions or tunnels that are down on purpose go into `known_down.yaml` (per host, fnmatch patterns); they are
  still listed in the check output but keep the service OK.
