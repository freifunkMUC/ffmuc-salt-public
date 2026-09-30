# dhcp-server

DHCPv4 for the client networks on the gateways (`gw*`). Owned by
`@freifunkMUC/salt-stack` (see `CODEOWNERS`).

Two implementations, selected per gateway by a NetBox tag:

| Tag | Server | Config |
|---|---|---|
| none | isc-dhcp-server (unmaintained since 2022) | `dhcpd.conf` |
| `dhcp-kea` | Kea 3.0 from ISC's repository | `kea-dhcp4.conf.jinja` |

Both serve the same networks: one shared network per NetBox site prefix,
pool `.10`-`.254`, the gateway as router and resolver, 600 s default and
3600 s maximum lease time, and the same options (MTU 1280, captive portal,
DNR, UniFi and Omada controller address).

## Kea

- **Packages:** `isc-kea-dhcp4-server` and `isc-kea-hooks`, pinned to
  `3.0.4-*`. Override the version via `netbox:config_context:kea:version`;
  all Kea packages must share one version.
- **Config check:** the config is rendered to `/etc/kea/kea-dhcp4.conf` and
  checked with `kea-dhcp4 -t` before it is written (`check_cmd`). The check
  also requires every `br-<site>` interface to exist.
- **VRF:** on gateways with `vrf_external`, a drop-in runs kea-dhcp4 through
  `ip vrf exec` as root, like dhcpd before.
- **Ping check:** `libdhcp_ping_check.so` replaces dhcpd's `ping-check`. On
  DHCPDISCOVER Kea holds the offer and pings the address once, waiting up to
  1 s like dhcpd's `ping-timeout`. If it answers, the address is declined and
  the offer dropped, so the client retries and gets another address.
  Clients renewing their own active lease are not pinged. Declined addresses
  return to the pool after 1 h (`decline-probation-period`).
- **DNR (RFC 9463):** the option advertises DoH, DoT and DoQ on the anycast
  resolver (`netbox:config_context:dhcp:dnr_address`, default
  `185.150.99.255`). Unlike the raw dhcpd option it includes the resolver
  address, which RFC 9463 section 3.1.8 requires and Kea enforces.
- **Monitoring:** `/usr/local/bin/kea-pool-stats` reads the pool statistics
  from the control socket and prints the `dhcpd-pools` JSON format, so the
  telegraf measurements (`dhcpd_pools_*`) stay unchanged. With
  `--warning/--critical` it is the Icinga check `dhcp_pool_kea`. telegraf
  and nagios are added to the `_kea` group for socket access.

## Migrating a gateway

1. Add the NetBox tag `dhcp-kea` to the gateway.
2. Run a highstate. isc-dhcp-server is stopped and disabled, then Kea starts.
3. Check: `systemctl status isc-kea-dhcp4-server`, `kea-pool-stats`,
   `journalctl -u isc-kea-dhcp4-server`.

Leases are not migrated. With 600 s lease time, clients renew within minutes;
Kea hands out the requested address again if it is still free.

## Rollback

Remove the `dhcp-kea` tag and run a highstate. Kea is stopped and disabled,
and isc-dhcp-server starts again with its previous config.

## Tests

```
python3 -m unittest discover -s dhcp-server/tests
```
