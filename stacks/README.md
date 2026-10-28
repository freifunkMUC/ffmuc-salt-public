# Docker Compose stacks

Compose projects of the FFMUC Docker hosts, kept as code and deployed by
[Komodo](https://komo.do). Salt keeps managing the hosts themselves (Docker,
nebula, firewall, Komodo Periphery); the containers on them are managed here.

## Layout

```
stacks/<host>/<project>/compose.yaml
stacks/<host>/<project>/<config file>   # optional, non-secret only
stacks/build/<image>/                   # source of a local image used on several hosts
```

`<host>` is the short host name (`docker04`), `<project>` the compose project
name that `docker compose ls` shows on the host today. Komodo adopts a running
project by its project name, so keep it unchanged.

## Conventions

- Images are pinned by version and digest: `image: name:1.2.3@sha256:...`.
  Update both together.
- Every service has a `restart:` policy (`unless-stopped` or `always`).
- Add a `healthcheck:` when the image ships a way to check itself; for
  existing projects only after testing it, a failing check makes Komodo report
  the stack as unhealthy.
- Publish only the ports that are needed. Backends that are only reached by
  the webfrontends should bind to the host's nebula address
  (`"10.8.0.31:8085:3000"`) instead of `0.0.0.0`; the nebula firewall in
  `nebula/files/config.yml.jinja` decides who may connect.
- Bind mounts use absolute paths below `/srv/docker/<project>/`. Komodo runs
  compose from its own checkout (`/etc/komodo/stacks/<stack>/stacks/<host>/<project>`),
  so a relative `./data` would point into that checkout instead of the existing
  data.
- No `version:` key.
- Security fixes that upstream has not shipped yet go into a `Dockerfile`
  next to `compose.yaml` that patches the pinned upstream image, with
  `build: .`, `image: local/<name>:<tag>` and `pull_policy: build` on the
  service (Komodo builds it on deploy; Dependabot does not track it). Pin
  every `FROM` by digest and say in the Dockerfile when it can go. Currently:
  hedgedoc, whitebophir and bgpalerter for node2shell (CVE-2026-111497).
- No secrets in this repository: no passwords, tokens, client secrets, cookie
  or session secrets, keys. Not in compose files, not in config files, not in
  comments.

## Secrets and variables

Compose files reference secrets as environment variables (`${NAME}`). Komodo
fills them: the Stack's *Environment* maps each name to a Komodo variable or
secret (`NAME = [[NAME]]`), Komodo writes the result to `.env` in the run
directory and runs `docker compose --env-file .env`. Komodo does not
interpolate `[[...]]` inside compose files that come from git, only in the
Stack's environment.

Create the variables in Komodo under *Settings / Variables* and mark them as
secret. Values come from the running setup on the host; never commit them.

Komodo writes the environment to `.env` as it is, and compose expands `$` in
unquoted `.env` values. For a value with `$` (for example an apr1 or bcrypt
hash), put the reference in single quotes: `NAME = '[[NAME]]'`.

| Stack | Variables |
|---|---|
| `docker04/etherpad` | from `/srv/docker/etherpad/.env`: `ETHERPAD_MYSQL_HOST`, `ETHERPAD_MYSQL_ROOT_PASSWORD`, `ETHERPAD_MYSQL_USER`, `ETHERPAD_MYSQL_PASSWORD`, `ETHERPAD_TITLE`, `ETHERPAD_DEFAULT_PAD_TEXT`, `ETHERPAD_HOST_PORT`, `ETHERPAD_ADMIN_PASSWORD`, `ETHERPAD_ADMIN_USER`, `ETHERPAD_DB_TYPE`, `ETHERPAD_DB_HOST`, `ETHERPAD_DB_PORT`, `ETHERPAD_DB_USER`, `ETHERPAD_DB_PASS`, `ETHERPAD_DB_NAME`, `ETHERPAD_DB_CHARSET`, `ETHERPAD_NODE_ENV`, `ETHERPAD_IMPORT_EXPORT_RATE_LIMIT_WINDOW`, `ETHERPAD_IMPORT_EXPORT_MAX_REQ_PER_IP` (each mapped to the `.env` name without the prefix) |
| `docker04/hedgedoc` | `HEDGEDOC_DB_PASSWORD` (also the MariaDB user password), `HEDGEDOC_OAUTH2_CLIENT_SECRET`, `HEDGEDOC_SESSION_SECRET` |
| `docker04/dokuwiki` | none; `/srv/docker/dokuwiki/ldap.conf` stays on the host |
| `docker04/whitebophir` | none |
| `docker0{4,5,6,7}/diun` | `DIUN_SLACK_WEBHOOK_URL` (`webhookURL` from `/srv/docker/diun/diun.yml`) |
| `docker07/libretranslate` | none |
| `docker0{5,7}/speedtest` | none |
| `docker0{4,6}/packetyeeter-analyzer` | none |
| `docker0{4,5,6,7}/meet-reserve` | `MEET_RESERVE_PRIVATE_KEY`, `MEET_RESERVE_POW_KEY`, `MEET_RESERVE_SYNC_KEY` (`RESERVE_*` from `/srv/docker/meet-reserve/.env`, same on all hosts) |
| `docker05/cryptpad` | none; `/srv/docker/cryptpad/data/config.js` and `infra.js` stay on the host |
| `docker05/salt-master` | none |
| `docker07/bgpalerter` | none; `/srv/docker/bgpalerter/volume/config.yml` stays on the host |
| `docker0{4,5,6,7}/traefik` | `TRAEFIK_DASHBOARD_USERS` (docker05, docker06, docker07), `TRAEFIK_DASHBOARD_USERS_DOCKER04` (docker04): `user:hash` of the dashboard basic auth, without the `$$` escapes. `traefik.yml`, `acme.json` and `update-dns.sh` (Salt state `certs`) stay on the host |
| `docker0{4,5,6,7}/wgkex` | `WGKEX_EMQX_NODE_COOKIE` (`EMQX_NODE__COOKIE`, same on all hosts). `config/broker/wgkex.yaml` stays on the host (the Salt state `telegraf` reads it too) |
| `docker04/conferencemapper` | none |
| `docker04/excalidraw-backend` | none |

## Deployment

- One Komodo Stack per directory: repo `freifunkMUC/ffmuc-salt-public`,
  branch `main`, run directory `stacks/<host>/<project>`, file
  `compose.yaml`, server `<host>`. Stack names are `<host>-<project>`
  (several hosts run a `diun` or `traefik`), with `project_name = "<project>"`.
- The Komodo resources (servers, stacks) are declared as TOML in
  `stacks/komodo-sync/` and applied by the Resource Sync `ffmuc-salt-public`,
  so the Komodo configuration is code as well. Changes in the UI that are not
  in the TOML show up as pending sync diffs. The sync never deletes
  (`delete = false`) and does not deploy (`deploy = false` on every Stack).
- Projects that are not in this repository yet are listed with
  `files_on_host = true` and their existing directory as `run_directory`, so
  Komodo shows them without changing anything. Taking one over means moving
  its compose file here and switching the Stack to `repo`. The projects on
  mail01 stay with the mailserver role of GoliathLabs/ansible.
- Komodo reads `files_on_host` compose files into its database, so projects
  with literal secrets in their compose files are left out until their secrets
  have moved: docker04 `cfssl`, `tuwunel-test`; docker05 `nextcloud`, `unifi`;
  docker06 `graylog`, `mastodon`; docker07 `akvorado`, `keycloak`,
  `vaultwarden`; mail01 `mailserver`; rw-vpn01/02 `wg-access-server`.
- Taking over a running project: create the variables, sync, compare the
  Stack's diff, then *Deploy*. The old `/srv/docker/<project>/docker-compose.y*ml`
  stays on the host as rollback: `docker compose -p <project> -f <old file> up -d`
  in that directory restores the previous state, the data directories are the
  same.
- Some projects came from Salt states that rendered their compose file on
  the host. Their compose files are now static per host in this directory and
  the Salt states are removed, so Salt and Komodo do not both manage them:
  `diun`, `libretranslate`, `meet-reserve`, `speedtest`,
  `packetyeeter-analyzer`.
- `docker07/libretranslate` keeps its models in the named volume
  `libretranslate_models`. The NetBox config context `libretranslate`
  (`enabled`, `port`) still opens the nebula-meet firewall for jigasi; keep
  `port` equal to the published port in `compose.yaml`.
- `meet-reserve` is built from `stacks/build/meet-reserve` on deploy. The
  NetBox config context `meet_reserve` (`enabled`, `signers`, `metrics_port`)
  still drives the nebula firewall and telegraf. When the signers change,
  update `RESERVE_PEERS` in every `meet-reserve/compose.yaml` too. A new
  signer needs `/srv/docker/meet-reserve/data` owned by `65532:65532`, mode
  `0700`.
- `whitebophir` v2 only opens canonical board names (lower case, no trailing
  `-`). Before the first v2 start, run
  `docker04/whitebophir/migrate-board-names.mjs` once. It copies the v1 boards
  with other names, see the comment in the file. The nginx location `/draw/`
  (`nginx/domains/ffmuc.net.include`) must not rewrite `/draw/tools/` to
  `/boards/tools/`; v2 serves the tools only below `/tools/`.
- `packetyeeter-analyzer` mounts the GeoIP files and data directories that
  the Salt state `packetyeeter` creates. Apply that state on a new host first.

## Komodo

Komodo v2.3.4: Core with MongoDB on docker06 (`stacks/docker06/komodo`),
Periphery as systemd service on every managed host (Salt state
`komodo-periphery`). MongoDB is the backend the Komodo docs recommend;
FerretDB/Postgres is only suggested for CPUs without AVX, docker06 has AVX2.

### Core on docker06

- Reachable only inside nebula as `komodo.ov.ffmuc.net`, through Traefik on
  docker06 like `log.ov.ffmuc.net` (labels on `core`, network `proxy`,
  certificate via DNS-01). The name comes from the NetBox service
  `komodo.in.ffmuc.net` on docker06 (`cname: true`, `public: false`).
  Core connects to the Periphery agents, not the other way round; GitHub
  webhooks do not reach it, the Resource Sync runs on its schedule.
- Login only via OIDC against Keycloak, local login is off. The first user who
  logs in becomes super admin; later users are created disabled and an admin
  enables them. Keycloak client: confidential, redirect URI
  `<KOMODO_HOST>/auth/oidc/callback`.
- Bootstrap once by hand, as root on docker06:
  ```
  git clone https://github.com/freifunkMUC/ffmuc-salt-public /srv/docker/komodo/checkout
  cd /srv/docker/komodo/checkout/stacks/docker06/komodo
  install -m 600 /dev/null .env   # fill in the variables below
  docker compose -p komodo up -d
  ```
  Log in first (to become admin), create the variables below as Komodo
  secrets, create the Resource Sync `ffmuc-salt-public` by hand once (repo
  `freifunkMUC/ffmuc-salt-public`, branch `main`, resource path
  `stacks/komodo-sync`) and run it. From then on the sync manages itself
  (`sync.toml`). The `docker06-komodo` Stack lets Komodo show Core and
  MongoDB; redeploy Core from a shell rather than from its own UI.
- Variables (bootstrap `.env` and Komodo secrets): `KOMODO_HOST`
  (`https://komodo.ov.ffmuc.net`), `KOMODO_DATABASE_PASSWORD`,
  `KOMODO_JWT_SECRET`, `KOMODO_WEBHOOK_SECRET`, `KOMODO_OIDC_PROVIDER`
  (`https://<keycloak>/realms/<realm>`), `KOMODO_OIDC_CLIENT_ID`,
  `KOMODO_OIDC_CLIENT_SECRET`.
- Data below `/srv/docker/komodo/`: `mongo/`, `keys/` (Core key pair),
  `backups/` (database dumps of Komodo's backup procedure).

### Periphery

- Salt state `komodo-periphery`, enabled per host by NetBox config context:
  ```
  {"komodo": {"periphery": {"enabled": true}}}
  ```
  Options and defaults: `komodo-periphery/defaults.yaml`. docker06 also needs
  the Core container network in `allowed_ips`, because Core reaches the local
  Periphery from `172.31.255.0/28`:
  ```
  {"komodo": {"periphery": {"enabled": true, "allowed_ips": ["10.8.0.15", "172.31.255.0/28"]}}}
  ```
- Pillar on the master (not in this repo): `komodo:core_public_key`, the Core
  public key from *Settings* in the Komodo UI (or
  `/srv/docker/komodo/keys/core.pub`). Periphery only accepts Core with this
  key; without it the state fails instead of starting an unauthenticated
  agent. Komodo v2 replaced the old passkeys with these key pairs.
- Periphery binds to the host's nebula address on port 8120, accepts only
  docker06 (`allowed_ips` plus the nebula firewall rule), and runs as root
  with its working directory `/etc/komodo`. Shell terminals are disabled,
  container terminals are allowed.
- Updating: bump `version` and both `sha256` values in `defaults.yaml`
  (digests from the GitHub release assets) together with the Core image.

### Rollout

1. Merge, bootstrap Core, configure Keycloak and the variables.
2. Enable the config context on docker06 and docker04, set the pillar,
   `state.apply komodo-periphery` and `nebula` on both.
3. Run the sync; the servers `docker04` and `docker06` should become healthy.
4. Take over the docker04 stacks one by one (see Deployment).
5. Further hosts (docker05, docker07, rw-vpn01, rw-vpn02, mail01): set
   `enabled = true` in `servers.toml`, enable the config context,
   `state.apply komodo-periphery,nebula` on the host, run the sync.

## Salt master

`docker05/salt-master` is the Salt master itself (Stack `docker05-salt`,
project `salt`), so Komodo only shows it and never deploys it, like Core
itself (a broken deploy would take away the tool used to repair the hosts).

- The master's cache is a host volume: `/srv/docker/salt/cache` (`./cache` on
  the host) is mounted to `/var/cache/salt/master`.
- After the master container is recreated, run
  `salt-run saltutil.sync_all` in it. The custom ext_pillar
  `_pillar/netbox.py` is loaded from the master's extmods cache; on
  2026-10-18 a recreate without the sync left every pillar without `netbox`.
- Then check:
  - `salt '*' test.ping` and `salt-run manage.down`: the same minions as
    before the recreate.
  - `salt 'docker04*' pillar.get netbox:config_context`: not empty.
  - `salt '*' pillar.get _errors`: empty on all minions.
- The minions need no sync. The mine data is in the cache volume and stays.
