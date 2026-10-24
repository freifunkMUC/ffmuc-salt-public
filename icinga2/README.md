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
  Hosts without that (the Jitsi hosts in `nebula-meet`) get `icinga2_agentless`.
- Agentless hosts have `vars.agentless = true`; every rule that runs a check on the agent has
  `ignore where host.vars.agentless`. Add that line to new rules with `command_endpoint`.
- A host in `static_hosts.yaml` is skipped once a minion of the same name has one of the two tags.
- A minion only appears after it has answered the mine (`salt-run manage.down` lists those that do not).

## BGP and WireGuard

- `bgp_sessions` (`plugins/check_bird_bgp_sessions`): CRITICAL when a BGP protocol in bird is not Established,
  hard after about 10 minutes. Roles `webserver-external`, `nextgen-gateway`, `freifunk-transit`.
- `wireguard_handshakes` (`plugins/check_wireguard_handshakes`): CRITICAL when a peer had no handshake for 600 s,
  including peers that never had one. Role `freifunk-transit` only; the gateways' peers are wgkex nodes.
- Both run `birdc show protocols` / `wg show all latest-handshakes` through sudo (`icinga2.sudoers`).
- Sessions or tunnels that are down on purpose go into `known_down.yaml` (per host, fnmatch patterns); they are
  still listed in the check output but keep the service OK.
