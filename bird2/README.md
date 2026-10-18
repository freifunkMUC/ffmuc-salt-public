# bird2 Salt formula

Configures bird2 for BGP/OSPF. On the webfrontends (wf03–wf06) bird announces the anycast resolver addresses to
the site router. This README covers how to **gracefully drain** a webfrontend before maintenance.

## Draining a webfrontend (`bgp_drain` grain)

Use this before anything that interrupts traffic on a webfrontend: package upgrades, haproxy/dnsdist restarts,
reboots, kernel updates.

### How it works

- Each webfrontend announces the anycast addresses (5.1.66.255, 185.150.99.255, 2001:678:e68:f000::,
  2001:678:ed0:f000::) via eBGP to its site router (AS212567). It uses a private ASN per site: **65101 = vie01
  (wf03, wf04)**, **65102 = muc01 (wf05, wf06)**.
- With the grain `bgp_drain: True`, `files/bird.conf.jinja2` prepends the host's own ASN three times on these exports
  (`EXTERNAL_OUT` / `EXTERNAL6_OUT`). The site router then prefers the other webfrontend at the same site.
- Effect: **new** connections (HTTPS, DoH, DoT, DoQ, plain DNS) move to the other host immediately, and **existing**
  connections finish normally. The drained host stays announced, so it still takes traffic as a backup if its
  partner fails.
- There's no BGP session reset and no withdrawal. Traffic stays at the same site.

### Rules

- **Drain only one host per site at a time.** If both hosts at a site are drained, their AS paths are equal again
  and nothing is drained.
- **The grain survives highstates and reboots.** A drained host stays drained until you remove the grain. Don't
  forget to undrain.
- **Render only the bird config file, with `state.sls_id bird2_config bird2`.** `state.apply bird2` also runs the
  `systemd-networkd` state.

### Commands

Run these on the Salt master from `/srv/docker/salt`:

```bash
cd /srv/docker/salt
H=webfrontend03.in.ffmuc.net
salt() { docker compose exec -T salt-master salt "$@"; }
```

**1. Drain**

```bash
salt $H grains.setval bgp_drain True
salt $H state.sls_id bird2_config bird2
salt $H cmd.run 'birdc configure'
```

**2. Check that the prepend is exported.** Both address families should show the ASN three times, for example
`BGP.as_path: 65101 65101 65101`:

```bash
salt $H cmd.run 'for p in $(birdc show protocols | awk "/BGP/{print \$1}"); do echo "$p: $(birdc show route export $p all | grep -m1 -oE "BGP.as_path:.*")"; done' shell=/bin/bash
```

**3. Wait for traffic to drain.** `ConnRate` (new connections/s) should drop to 0 within seconds. `CurrConns` falls to
a few dozen within 2–5 minutes as existing connections finish:

```bash
salt $H cmd.run 'echo "show info" | socat - /run/haproxy/admin.sock | grep -E "^(CurrConns|ConnRate):"'
```

If `ConnRate` stays above 0 after a minute, the drain isn't working, for example because the other host at the site
is drained or down. Undrain and investigate before you continue.

**4. Do the maintenance.** Note that the haproxy package's postinst only *reloads* haproxy on upgrade. If you need a
full restart (e.g. to pick up systemd unit or mount changes), do it now:

```bash
salt $H cmd.run 'haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl restart haproxy'
```

**5. Undrain**

```bash
salt $H grains.delkey bgp_drain
salt $H state.sls_id bird2_config bird2
salt $H cmd.run 'birdc configure'
```

**6. Check that traffic is back.** The command from step 2 should now show an empty `BGP.as_path` (bird adds our ASN
only when sending). After about a minute, `ConnRate` should be back at its usual level (roughly 30–50 per host
during the day):

```bash
salt $H cmd.run 'echo "show info" | socat - /run/haproxy/admin.sock | grep -E "^(CurrConns|ConnRate):"'
```

**7. Wait a minute or two, then move on to the next host.**

### Check whether anything is still drained

```bash
docker compose exec -T salt-master salt 'webfrontend*' grains.get bgp_drain
```

An empty result means the host isn't drained.
