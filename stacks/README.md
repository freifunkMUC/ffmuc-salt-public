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
- Every service has `restart: unless-stopped`.
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
  hedgedoc and bgpalerter for node2shell
  (CVE-2026-111497).
- No secrets in this repository: no passwords, tokens, client secrets, cookie
  or session secrets, keys. Not in compose files, not in config files, not in
  comments. See Secrets.
- Taking a project over: see the checklist under Secrets.

## Secrets

Secrets never go into this repository, into compose files or into Komodo Core:
Core variables end up in its database, its update log and its backups. The
source is the Salt pillar; Salt renders each host's secrets into the
`[secrets]` table of its Periphery config, and Periphery fills them in when it
deploys. Core only knows the names.

```
pillar komodo:periphery:secrets:<NAME>       master: /srv/docker/salt/pillar/komodo-secrets/<host>.sls
  -> state komodo-periphery                  /etc/komodo/periphery.config.toml [secrets], 0600
  -> Stack environment  VAR = [[<NAME>]]     resolved by Periphery on deploy
  -> .env in the run directory (0600)        compose reads ${VAR}
```

- Names are `<APP>_<KEY>` in upper case (`ETHERPAD_DB_PASS`).
- Pillar files below `komodo-secrets/` are `#!yaml` (no Jinja), mode 0640,
  and `top.sls` maps each one to its minion only:
  `'docker04.in.ffmuc.net': [komodo-secrets.docker04]`. Never in NetBox
  config contexts.
- The config file is managed with `show_changes: False`, so values do not show
  up in Salt output. Periphery reads its config only at start; the state
  restarts it on change. Running containers are not affected.
- No Core variable with the same name: Core interpolates `[[...]]` first, its
  value would win.
- Only real secrets: Periphery replaces every occurrence of a secret's value
  in the deploy logs with its name, so a short or common value (`1`, `mysql`,
  `etherpad`) garbles them. Plain settings stay literal in the compose file.
- Values: printable ASCII without `$`, without leading quotes and without
  ` #`. Komodo writes `.env` as plain `VAR=value`, compose interpolates `$`, and
  Komodo masks a secret in its logs and in the stored `docker compose config`
  output only where it appears verbatim.
- `[[...]]` works in the Stack's environment and pre/post deploy commands, not
  inside compose files from git. Images that want `*_FILE` get a file that
  lives on the host outside the repo (for example managed by Salt).

Stacks taken over before the pillar existed still use Komodo Core variables
(`NAME = [[NAME]]` in the Stack environment, under *Settings / Variables* in
Core). Move them to the pillar one by one, see *Taking a project over*. Until
then: Komodo writes the environment to `.env` as it is, and compose expands
`$` in unquoted `.env` values. For a value with `$` (for example an apr1 or
bcrypt hash), put the reference in single quotes: `NAME = '[[NAME]]'`.

| Stack | Secrets |
|---|---|
| `docker04/etherpad` | `ETHERPAD_ADMIN_PASSWORD`, `ETHERPAD_DB_PASS`, `ETHERPAD_MYSQL_ROOT_PASSWORD` from `/srv/docker/etherpad/.env`; the other keys there are plain settings (now literal in `compose.yaml`) or unused |
| `docker04/hedgedoc` | `HEDGEDOC_DB_PASS` (also the MariaDB user password), `HEDGEDOC_CMD_OAUTH2_CLIENT_SECRET`, `HEDGEDOC_CMD_SESSION_SECRET`, from `/srv/docker/hedgedoc/docker-compose.yaml` |
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
| `docker04/matomo` | `MATOMO_DB_ROOT_PASSWORD`, `MATOMO_DB_PASSWORD` (from `/srv/docker/matomo/db.env`). `nginx.conf` stays on the host |
| `docker04/netbox` | `NETBOX_DB_PASSWORD`, `NETBOX_REDIS_PASSWORD` (redis and redis-cache), `NETBOX_SECRET_KEY`, `NETBOX_SUPERUSER_API_TOKEN`, `NETBOX_SUPERUSER_PASSWORD`, `NETBOX_AUTH_LDAP_BIND_PASSWORD`, `NETBOX_API_TOKEN_PEPPER_1` (from `/srv/docker/netbox/env/*.env`). The non-secret values are in `env/`. `configuration/` stays on the host |
| `docker04/netbox-parker` | `NETBOX_PARKER_DB_PASSWORD`, `NETBOX_PARKER_REDIS_PASSWORD`, `NETBOX_PARKER_REDIS_CACHE_PASSWORD`, `NETBOX_PARKER_SECRET_KEY`, `NETBOX_PARKER_API_TOKEN_PEPPER_1` (from `/srv/docker/netbox-parker/env/*.env`). The non-secret values are in `env/`. `configuration/` stays on the host |
| `docker04/openldap` | `OPENLDAP_LAM_PASSWORD` (`LAM_PASSWORD` from `/srv/docker/openldap/.env`). `ldif/`, `slapd-data/` and `certs/` stay on the host |
| `docker04/owncast` | none. `data/`, `db/` and `logo.png` stay on the host |
| `docker05/mattermost-docker` | `MATTERMOST_POSTGRES_PASSWORD` (`POSTGRES_PASSWORD` from `/srv/docker/mattermost-docker/.env`). The other `.env` values are now in the compose files |
| `docker06/mastodon-paywall` | `MASTODON_PAYWALL_API_TOKEN`, `MASTODON_PAYWALL_PAYPAL_CLIENT_ID`, `MASTODON_PAYWALL_PAYPAL_CLIENT_SECRET`, `MASTODON_PAYWALL_PAYPAL_WEBHOOK_ID` (from `/srv/docker/mastodon-paywall/.env`) |
| `docker06/omada` | none. `data/`, `work/` and `logs/` stay on the host |
| `docker07/peeringmanager` | `PEERINGMANAGER_SECRET_KEY`, `PEERINGMANAGER_DB_PASSWORD`, `PEERINGMANAGER_REDIS_PASSWORD`, `PEERINGMANAGER_REDIS_CACHE_PASSWORD`, `PEERINGMANAGER_PEERINGDB_PASSWORD`, `PEERINGMANAGER_PEERINGDB_API_KEY` (from `/srv/docker/peeringmanager/env/*.env`). The non-secret values are in `env/`. `configuration/` stays on the host |
| `docker07/uisp` | none. `data/` stays on the host |
| `docker04/cfssl` | `CFSSL_POSTGRES_PASSWORD` (`POSTGRES_PASSWORD` from `/srv/docker/cfssl/docker-compose.yml`). `config/` stays on the host (`db_config.json` has the database password) |
| `docker05/nextcloud` | `NEXTCLOUD_MYSQL_ROOT_PASSWORD`, `NEXTCLOUD_MYSQL_PASSWORD`, `NEXTCLOUD_REDIS_PASSWORD` (from `/srv/docker/nextcloud/docker-compose.yml`). `config/` is now in git. `nginx.conf` stays on the host (it lists internal networks) |
| `docker05/zammad` | `ZAMMAD_POSTGRES_PASS` (`POSTGRES_PASS` from `/srv/docker/zammad-docker-compose/.env`). The other `.env` values are in the Stack environment in `stacks.toml`. `ELASTICSEARCH_PASS` is not a secret, Elasticsearch runs without security |
| `docker05/unifi` | `UNIFI_MONGO_PASS` (`MONGO_PASS` from `/srv/docker/unifi/docker-compose.yml`). `init-mongo.js` stays on the host (it has the database password) |
| `docker06/graylog` | `GRAYLOG_PASSWORD_SECRET`, `GRAYLOG_ROOT_PASSWORD_SHA2` (from `/srv/docker/graylog/.env`), `GRAYLOG_OPENSEARCH_INITIAL_ADMIN_PASSWORD` (from `/srv/docker/graylog/docker-compose.yml`). `GeoLite2-City.mmdb` stays on the host |
| `docker06/mastodon` | `MASTODON_DB_PASS` (also `POSTGRES_PASSWORD`), `MASTODON_SECRET_KEY_BASE`, `MASTODON_OTP_SECRET`, `MASTODON_VAPID_PRIVATE_KEY`, `MASTODON_SMTP_PASSWORD`, `MASTODON_ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `MASTODON_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, `MASTODON_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` (from `/srv/docker/mastodon/.env.production`), `MASTODON_TRUSTED_PROXY_IP` (not secret, it lists internal addresses). The other values that are not secret are in `env/mastodon.env` |
| `docker07/akvorado` | none. `config/` stays on the host (`outlet.yaml` has the SNMP community) |
| `docker07/keycloak` | `KEYCLOAK_DB_PASSWORD` (`POSTGRES_PASSWORD` and `KC_DB_PASSWORD`), `KEYCLOAK_ADMIN_PASSWORD` (from `/srv/docker/keycloak/docker-compose.yml` and `keycloak.env`). The values that are not secret are in `env/keycloak.env` |
| `docker07/vaultwarden` | `VAULTWARDEN_ADMIN_TOKEN` (from `/srv/docker/vaultwarden/.env`, an argon2 hash with `$`, so it is single-quoted in `stacks.toml`), `VAULTWARDEN_SSO_CLIENT_SECRET` (from `/srv/docker/vaultwarden/docker-compose.yaml`) |
| `docker06/komodo` | none in Komodo; Core's own secrets stay in its bootstrap `.env` |
| `docker07/tuwunel` | `TUWUNEL_OIDC_CLIENT_SECRET` (Keycloak client `matrix` in realm `ffmuc`) |
| `docker07/element-web` | none; `config.json` is public anyway |

### Taking a project over

One project at a time:

1. Secrets into the pillar. With the admin script
   `pillar-secrets-from-env.sh <host> <app> check`, then `apply [KEY ...]`: it
   reads `.env` and literal secret values of the compose files on the host as
   root and writes them straight into the pillar file on the master, printing
   names only. By hand: `komodo: periphery: secrets: <NAME>: <value>` in
   `komodo-secrets/<host>.sls` plus the `top.sls` entry.
2. `salt '<host>.in.ffmuc.net' saltutil.refresh_pillar`, check the names with
   `pillar.keys komodo:periphery:secrets`, then
   `state.apply komodo-periphery test=True` and for real.
3. Move the compose file to `stacks/<host>/<project>/compose.yaml`: literal
   secrets become `${VAR}`, the project goes through the checklist below, the
   Stack in `stacks.toml` switches from `files_on_host` to the repo with
   `environment` lines `VAR = [[<NAME>]]`. PR, merge, run the sync.
4. Compare the Stack's diff in Komodo, *Deploy*, check the service. Rollback:
   the old compose file on the host (see Deployment).
5. Rotate every secret that was in the old files (they are in old copies and
   backups): new value into the pillar, `state.apply komodo-periphery`,
   redeploy; database passwords also in the database. Then remove the old
   `.env` and literal values on the host.

### Checklist

Compare with the upstream project's current recommended deployment (official
compose example and docs), then bring the project to:

- [ ] image `name:version@sha256:...`, picked up by Renovate
- [ ] `restart: unless-stopped`
- [ ] non-root `user:` where the image supports it
- [ ] `read_only: true` plus `tmpfs:` for the paths it writes, where the app allows it
- [ ] `cap_drop: [ALL]`, `cap_add` only for what is needed
- [ ] `security_opt: ["no-new-privileges:true"]`
- [ ] `healthcheck:` from upstream or tested
- [ ] memory and CPU limits (`mem_limit`, `cpus`), sized from `docker stats`
- [ ] secrets only as `${VAR}` from the Periphery secrets or as `*_FILE`
- [ ] ports only where needed, backends on the nebula address
- [ ] data in absolute bind mounts below `/srv/docker/<project>/`

Note deviations from upstream and the reason in the PR.

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
- Projects that are not in this repository are listed with
  `files_on_host = true` and their existing directory as `run_directory`, so
  Komodo shows them without changing anything. Taking one over means moving
  its compose file here and switching the Stack to `repo`. The projects on
  mail01 stay on the host (mailserver role of GoliathLabs/ansible).
- Projects that come from an upstream compose repository (`docker04/netbox`,
  `docker04/netbox-parker`, `docker07/peeringmanager`) keep the upstream file
  layout: `compose.yaml` is the upstream file, `compose.override.yaml` has
  the local changes, and `env/*.env` has the values that are not secret. To
  update, compare `compose.yaml` and `env/` with the new upstream release.
  `docker05/zammad` (zammad/zammad-docker-compose) has the same layout, but
  without `env/`: the image pins are in `compose.override.yaml`, the values
  that `compose.yaml` reads from `.env` are in the Komodo Stack environment.
  Its directory name is not the project name: the project stays
  `zammad-docker-compose`, so Komodo adopts the running containers.
  `docker07/akvorado` keeps the upstream `docker/` directory unchanged
  (only the files in use, without the geoip build files) and has all local
  changes in `ffmuc/docker-compose-ffmuc.yml`, the last file in `file_paths`.
- Komodo reads `files_on_host` compose files into its database, so projects
  with literal secrets in their compose files are left out until their secrets
  have moved: docker04 `tuwunel-test`; mail01 `mailserver`; rw-vpn01/02 `wg-access-server`.
- Taking over a running project: see *Taking a project over*, then compare
  the Stack's diff and *Deploy*. The old `/srv/docker/<project>/docker-compose.y*ml`
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
  Log in first (to become admin), create the Resource Sync `ffmuc-salt-public` by hand once (repo
  `freifunkMUC/ffmuc-salt-public`, branch `main`, resource path
  `stacks/komodo-sync`) and run it. From then on the sync manages itself
  (`sync.toml`). The `docker06-komodo` Stack lets Komodo show Core and
  MongoDB; redeploy Core from a shell rather than from its own UI.
- Variables (bootstrap `.env` only, never as Komodo variables): `KOMODO_HOST`
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

1. Merge, bootstrap Core, configure Keycloak.
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
