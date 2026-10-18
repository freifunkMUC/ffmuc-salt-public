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
name that `docker compose ls` shows on the host today. Komodo uses the project
name to adopt a running project, so keep it unchanged.

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

| Stack | Variables |
|---|---|
| `docker04/etherpad` | from `/srv/docker/etherpad/.env`: `ETHERPAD_MYSQL_HOST`, `ETHERPAD_MYSQL_ROOT_PASSWORD`, `ETHERPAD_MYSQL_USER`, `ETHERPAD_MYSQL_PASSWORD`, `ETHERPAD_TITLE`, `ETHERPAD_DEFAULT_PAD_TEXT`, `ETHERPAD_HOST_PORT`, `ETHERPAD_ADMIN_PASSWORD`, `ETHERPAD_ADMIN_USER`, `ETHERPAD_DB_TYPE`, `ETHERPAD_DB_HOST`, `ETHERPAD_DB_PORT`, `ETHERPAD_DB_USER`, `ETHERPAD_DB_PASS`, `ETHERPAD_DB_NAME`, `ETHERPAD_DB_CHARSET`, `ETHERPAD_NODE_ENV`, `ETHERPAD_IMPORT_EXPORT_RATE_LIMIT_WINDOW`, `ETHERPAD_IMPORT_EXPORT_MAX_REQ_PER_IP` (each mapped to the `.env` name without the prefix) |
| `docker04/hedgedoc` | `HEDGEDOC_DB_PASSWORD` (also the MariaDB user password), `HEDGEDOC_OAUTH2_CLIENT_SECRET`, `HEDGEDOC_SESSION_SECRET` |
| `docker04/dokuwiki` | none; `/srv/docker/dokuwiki/ldap.conf` stays on the host |
| `docker05/salt-master` | none |

## Deployment

- One Komodo Stack per directory: repo `freifunkMUC/ffmuc-salt-public`,
  branch `main`, run directory `stacks/<host>/<project>`, file
  `compose.yaml`, server `<host>`, Stack name = compose project name.
- The Komodo resources (servers, stacks, non-secret variables) are declared as
  TOML and applied by a Komodo Resource Sync, so the Komodo configuration is
  code as well. Changes in the UI that are not in the TOML show up as pending
  sync diffs.
- Taking over a running project: create the variables, sync, compare the
  Stack's diff, then *Deploy*. The old `/srv/docker/<project>/docker-compose.y*ml`
  stays on the host as rollback: `docker compose -p <project> -f <old file> up -d`
  in that directory restores the previous state, the data directories are the
  same.

## Salt master

`docker05/salt-master` is the Salt master itself, so it is kept here as
reference and is not deployed by Komodo for now (a broken deploy would take
away the tool used to repair the hosts).

- The master's cache is a host volume: `/srv/docker/salt/cache` (`./cache` on
  the host) is mounted to `/var/cache/salt/master`.
- After the master container is recreated, run
  `salt-run saltutil.sync_all` in it. The custom ext_pillar
  `_pillar/netbox.py` is loaded from the master's extmods cache; on
  2026-10-18 a recreate without the sync left every pillar without `netbox`.
