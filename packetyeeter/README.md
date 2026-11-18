# packetyeeter Salt formula

Standalone formula for explicit targeting only.

> **Safety default: enforcement is OFF.** `collector.dry_run` defaults to
> `true`, and the analyzer stack runs with `-dry-run`. Neither daemon will
> block/drop any traffic until an operator sets `dry_run: false` in
> `config_context:packetyeeter` and removes `-dry-run` from the stack. Confirmed upstream behavior: with dry-run
> set, the collector's own kernel-space detections (bad flags, SYN-flood,
> ICMP/UDP rate limits) and even `-policy block` overrides log/count only;
> the analyzer never sends BLOCK commands. Only disable dry-run after
> reviewing logs/metrics per the project's staged-rollout guidance
> (analyzer dry-run -> one collector canary -> wider rollout).

This formula is intentionally **not** referenced from `top.sls` and should be
applied manually to selected hosts:

```bash
salt '<target>' state.apply packetyeeter
```

## Enablement: tags, not config_context

Whether this formula does anything is controlled purely by Netbox tags
(`netbox:tag_list`):

- `packetyeeter-collector` -> installs/runs the collector (enforcer) on this host
- `packetyeeter-analyzer`  -> prepares the analyzer (decision service) data and GeoIP files on this host

A host can carry either tag, both, or neither. No `config_context` entry is
required to activate the formula - tagging alone is enough for both
components. The collector installs the `.deb` of the default release version
(currently `0.2.0`). The analyzer container is a Komodo stack, see below.

## Deployment model

- **Collector** (`packetyeeter-collector` tag): installed from the project's
  official **`.deb` package** (built with nfpm, published per release), which
  ships its own systemd unit, required capabilities (`CAP_SYS_ADMIN`,
  `NET_ADMIN`, `BPF`, `PERFMON`, `NET_RAW`, unlimited memlock), and
  `/etc/default/packetyeeter-collector` template. Native install is required
  since it loads eBPF/XDP/TC programs against a host network interface - not
  practical to containerize. This formula only manages the env file content
  and enables/starts the package-provided service; it does not ship its own
  binary or systemd unit.
- **Analyzer**: runs as a **Docker container** from the official image
  (`ghcr.io/awlx/packetyeeter-analyzer`). Komodo deploys it from
  [`stacks/<host>/packetyeeter-analyzer/compose.yaml`](../stacks). The image,
  flags, ports and Traefik host are set in that file. The
  `packetyeeter-analyzer` tag only makes this formula create
  `/srv/docker/packetyeeter-analyzer/{data,ml-data,ml-data/sessions}` and
  download the GeoIP files to `/srv/docker/packetyeeter-analyzer/geoip/`.
  When you bump `default_version`, bump the analyzer image in the stack too.

## Defaults

| Setting | Default |
| :--- | :--- |
| collector version | `0.2.0` (matches the published release tag `v0.2.0`). The `.deb` filename embeds the version (nfpm default `packetyeeter-collector_<version>_amd64.deb`); override `config_context:packetyeeter:collector:version` to pin a newer release once available, or set `deb_url` directly to override the computed URL entirely. |
| collector allowlist | auto-computed from this site's own Netbox-registered prefixes (`netbox:site:prefixes`), comma-joined. Excludes the site's own IP ranges from both the collector's kernel-space detections and the analyzer's reputation tracking (the SPOE handler checks the allowlist before ever emitting a signal, so the analyzer never sees allowlisted traffic). Override `config_context:packetyeeter:collector:allowlist` to add ranges beyond the site's own prefixes, or set it to an explicit value to replace the auto-computed list entirely. |
| collector interface | `eth0` |
| collector analyzer_addr | auto-discovered: the mine is queried for a host tagged `packetyeeter-analyzer` in the same Netbox site; falls back to `127.0.0.1:9090` if none is found |
| collector metrics_addr | `:2112` |
| collector spoe_port | `9876` |
| collector geoip_asn | `/etc/haproxy/geoip/GeoLite2-ASN.mmdb` if that file already exists on the host (reused from the haproxy formula), otherwise `/var/lib/GeoIP/GeoLite2-ASN.mmdb` |
| collector dry_run | `true` (safe by default) |
| collector egress_accounting / egress_min_bytes (v0.1.9+) | `true` / `1048576`. On by default - enables sustained-download egress accounting (feeds the analyzer's detection). `-egress-accounting` (and `-egress-min-bytes` alongside it) is only emitted into `EXTRA_ARGS` when `egress_accounting` is truthy, so an older (<=v0.1.8) collector binary never receives an unknown flag (which would exit 2 -> crash loop under `Restart=on-failure`); the formula upgrades the `.deb` to v0.1.9 before rendering the flag, so this is safe. Leave `egress_min_bytes` at the `1 MiB` floor. Set `egress_accounting: false` to disable. |

Per-DC analyzer discovery mirrors the same-site matching pattern already used
in [formulars/haproxy/haproxy.cfg](../haproxy/haproxy.cfg) (mine lookups on
`minion_location` / `minion_address`).

GeoIP: on webfrontends, `formulars/haproxy` already downloads
`GeoLite2-ASN.mmdb` to `/etc/haproxy/geoip`. The collector reuses that file
directly. The analyzer stack always mounts the copies in
`/srv/docker/packetyeeter-analyzer/geoip/` (ASN and Country) read-only.

## Optional overrides via config_context

`netbox:config_context:packetyeeter` is **optional** and only needed to
override specific collector defaults, e.g. a custom binary location,
interface, or a non-default analyzer address:

```yaml
packetyeeter:
  collector:
    # version: "0.2.1"              # optional: override the default (0.2.0) once a newer release ships
    # deb_url: https://...          # optional: override the computed URL entirely
    interface: ens192
    analyzer_addr: 10.0.0.5:9090   # override auto-discovery if needed
    # allowlist: 203.0.113.0/24,198.51.100.0/24   # optional: extra ranges beyond this site's own prefixes
    dry_run: false
```

Any key you don't set keeps its built-in default.

## Behavior

- No `packetyeeter-collector`/`packetyeeter-analyzer` tag: state is a no-op (`test.nop`).
- Collector `version`/`deb_url` explicitly cleared to empty: state fails
  explicitly rather than guessing a package URL.
- Collector's officially packaged systemd service runs as root with required
  BPF/XDP capabilities (unchanged by this formula).
- Analyzer runs as the Komodo stack `<host>-packetyeeter-analyzer` (compose project
  `packetyeeter-analyzer`), with persistent state under `/srv/docker/packetyeeter-analyzer/data`
  (mounted at `/data`).

## Installed files

- `formulars/packetyeeter/init.sls`
- `formulars/packetyeeter/defaults.jinja` (shared default version; `haproxy` fetches the JA4/SPOE files from the same tag)
- `formulars/packetyeeter/packetyeeter-collector.default.jinja`
- `stacks/<host>/packetyeeter-analyzer/compose.yaml` (Komodo)

