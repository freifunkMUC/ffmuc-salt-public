# Docker Compose stacks

Compose projects of the FFMUC Docker hosts, kept as code and deployed by
[Komodo](https://komo.do). Salt keeps managing the hosts themselves (Docker,
nebula, firewall, Komodo Periphery); the containers on them are managed here.

## Layout

```
stacks/<host>/<project>/compose.yaml
stacks/<host>/<project>/<config file>   # optional, non-secret only
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

| Stack | Secrets |
|---|---|
| `docker04/etherpad` | `ETHERPAD_ADMIN_PASSWORD`, `ETHERPAD_DB_PASS`, `ETHERPAD_MYSQL_ROOT_PASSWORD` from `/srv/docker/etherpad/.env`; the other keys there are plain settings (now literal in `compose.yaml`) or unused |
| `docker04/hedgedoc` | `HEDGEDOC_DB_PASS` (also the MariaDB user password), `HEDGEDOC_CMD_OAUTH2_CLIENT_SECRET`, `HEDGEDOC_CMD_SESSION_SECRET`, from `/srv/docker/hedgedoc/docker-compose.yaml` |
| `docker04/dokuwiki` | none; `/srv/docker/dokuwiki/ldap.conf` stays on the host |
| `docker05/salt-master` | none |
| `docker06/komodo` | none in Komodo; Core's own secrets stay in its bootstrap `.env` |

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
- Taking over a running project: see Secrets, then compare the Stack's diff
  and *Deploy*. The old `/srv/docker/<project>/docker-compose.y*ml`
  stays on the host as rollback: `docker compose -p <project> -f <old file> up -d`
  in that directory restores the previous state, the data directories are the
  same.

## Komodo

Komodo v2.3.3: Core with MongoDB on docker06 (`stacks/docker06/komodo`),
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
