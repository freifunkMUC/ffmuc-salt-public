# packetyeeter Salt formula

Standalone formula for explicit targeting only.

> **Safety default: enforcement is OFF.** Both `collector.dry_run` and
> `analyzer.dry_run` default to `true`. Neither daemon will block/drop any
> traffic until an operator explicitly sets `dry_run: false` in
> `config_context:packetyeeter`. Confirmed upstream behavior: with dry-run
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
- `packetyeeter-analyzer`  -> installs/runs the analyzer (decision service) on this host

A host can carry either tag, both, or neither. No `config_context` entry is
required to activate the formula - tagging alone is enough for both
components. The collector and analyzer share one default release version
(currently `0.1.7`); the collector installs the matching `.deb`, and the
analyzer pulls the matching `ghcr.io/awlx/packetyeeter-analyzer:v0.1.7` image
(not `:latest`, for reproducible deploys).

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
- **Analyzer** (`packetyeeter-analyzer` tag): runs as a **Docker container**
  using the project's official image (`ghcr.io/awlx/packetyeeter-analyzer`),
  via `docker compose`, consistent with how other docker-host services in
  this repo are deployed (e.g. [formulars/docker-containers](../docker-containers)).

## Defaults

| Setting | Default |
| :--- | :--- |
| collector version | `0.1.7` (matches the published release tag `v0.1.7`). The `.deb` filename embeds the version (nfpm default `packetyeeter-collector_<version>_amd64.deb`); override `config_context:packetyeeter:collector:version` to pin a newer release once available, or set `deb_url` directly to override the computed URL entirely. |
| analyzer version / image | `0.1.7`, computed into `ghcr.io/awlx/packetyeeter-analyzer:v0.1.7` (CI publishes an image tagged with the release tag itself for every `vX.Y.Z` push - not `:latest`, for reproducible deploys). Override `config_context:packetyeeter:analyzer:version` to bump just the analyzer, or set `image` directly to override the computed reference entirely. Collector and analyzer versions are independent config keys - they only share the same *default*. |
| collector allowlist | auto-computed from this site's own Netbox-registered prefixes (`netbox:site:prefixes`), comma-joined. Excludes the site's own IP ranges from both the collector's kernel-space detections and the analyzer's reputation tracking (the SPOE handler checks the allowlist before ever emitting a signal, so the analyzer never sees allowlisted traffic). Override `config_context:packetyeeter:collector:allowlist` to add ranges beyond the site's own prefixes, or set it to an explicit value to replace the auto-computed list entirely. |
| collector interface | `eth0` |
| collector analyzer_addr | auto-discovered: the mine is queried for a host tagged `packetyeeter-analyzer` in the same Netbox site; falls back to `127.0.0.1:9090` if none is found |
| collector metrics_addr | `:2112` |
| collector haproxy_port / spoe_port | `8765` / `9876` |
| collector/analyzer geoip_asn | `/etc/haproxy/geoip/GeoLite2-ASN.mmdb` if that file already exists on the host (reused from the haproxy formula), otherwise `/var/lib/GeoIP/GeoLite2-ASN.mmdb` |
| analyzer geoip_country (v0.1.6+) | `/etc/haproxy/geoip/GeoLite2-City.mmdb` if it already exists on the host (reused from the haproxy formula - a City DB also contains country data), otherwise its own `GeoLite2-Country.mmdb` downloaded to `/srv/docker/packetyeeter-analyzer/geoip/`. Always enabled (no gate) - powers the Inspector's "Threats by Country" panel; gracefully degrades to "unknown" if the file is ever missing. |
| collector dry_run | `true` (safe by default) |
| analyzer listen_port / metrics_port / inspect_port | `9090` / `9091` / `9092` (inspect is published as `127.0.0.1:9092` only) |
| analyzer reputation_threshold | `75.0` (reputation score, not a percentage - an entity is marked a "Bad Actor" once its accumulated score exceeds this) |
| analyzer ai_confidence_threshold | `0.8` (raised from the upstream default of `0.7`, which was producing too many false positives in production - requires 80% AI confidence before flagging a bot/scraper) |
| analyzer dry_run | `true` (safe by default) |

Per-DC analyzer discovery mirrors the same-site matching pattern already used
in [formulars/haproxy/haproxy.cfg](../haproxy/haproxy.cfg) (mine lookups on
`minion_location` / `minion_address`).

GeoIP: on webfrontends, `formulars/haproxy` already downloads
`GeoLite2-ASN.mmdb` to `/etc/haproxy/geoip`. The collector reuses that file
directly. For the dockerized analyzer, if that same host path exists it is
bind-mounted read-only into the container at `/data/geoip/GeoLite2-ASN.mmdb`;
otherwise the container runs without ASN enrichment (GeoIP lookup failures
are non-fatal - the daemon logs a warning and continues).

## Optional overrides via config_context

`netbox:config_context:packetyeeter` is **optional** and only needed to
override specific defaults, e.g. a custom binary location, interface, or a
non-default analyzer address:

```yaml
packetyeeter:
  collector:
    # version: "0.2.0"              # optional: override the default (0.1.7) once a newer release ships
    # deb_url: https://...          # optional: override the computed URL entirely
    interface: ens192
    analyzer_addr: 10.0.0.5:9090   # override auto-discovery if needed
    # allowlist: 203.0.113.0/24,198.51.100.0/24   # optional: extra ranges beyond this site's own prefixes
    dry_run: false

  analyzer:
    # version: "0.2.0"              # optional: override the default (0.1.7) independently of the collector
    # image: ghcr.io/awlx/packetyeeter-analyzer:v0.2.0   # optional: override the computed image entirely
    reputation_threshold: 80.0
    ai_confidence_threshold: 0.85   # optional: override the default (0.8) if still seeing too many/few false positives
    dry_run: false
```

Any key you don't set keeps its built-in default.

## Behavior

- No `packetyeeter-collector`/`packetyeeter-analyzer` tag: state is a no-op (`test.nop`).
- Collector `version`/`deb_url` explicitly cleared to empty: state fails
  explicitly rather than guessing a package URL.
- Collector's officially packaged systemd service runs as root with required
  BPF/XDP capabilities (unchanged by this formula).
- Analyzer runs as a Docker container (`docker compose` in `/srv/docker/packetyeeter-analyzer`),
  with persistent state under `/srv/docker/packetyeeter-analyzer/data` (mounted at `/data`).

## Installed files

- `formulars/packetyeeter/init.sls`
- `formulars/packetyeeter/packetyeeter-collector.default.jinja`
- `formulars/packetyeeter/packetyeeter-analyzer-compose.yml.j2`

