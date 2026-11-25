# OpenWISP controller (docker07)

Stack after [docker-openwisp](https://github.com/openwisp/docker-openwisp) 26.09.5, for non-Gluon OpenWrt devices.
Public: `https://openwisp.ffmuc.net` (UI) and `https://openwisp-api.ffmuc.net` (device API) through HAProxy on the
webfrontends to nginx on `10.8.0.16:8098` (Nebula rule: webfrontend group only; `/admin/login` is 403 there, rate limit on `/accounts/`).
Break-glass: `https://openwisp.ov.ffmuc.net` (overlay, Traefik without `noc-auth`: the app logs in itself).

- Off: RADIUS, OpenVPN (management VPN, `VPN_DOMAIN` empty), postfix (mail goes to `mail01.fnmuc.net:587` as
  `no-reply@ffmuc.net`), topology, firmware upgrader. On: monitoring with InfluxDB 1.8.
- Login: Keycloak realm `chat`, client `openwisp`, only members of the group `openwisp` (`config/oidc_gate.py` checks the
  `groups` claim and makes members staff and syncs organizations, see below) (`config/custom_django_settings.py`, django-allauth `openid_connect`; mounted into the image, no derived image needed).
  Start at `/accounts/oidc/keycloak/login/`; the login page has no provider button.
  New users have no rights until a Keycloak subgroup gives them an organization (below).
- Break-glass: local superuser `admin` on `/admin/login/` at the overlay name.

## Access per organization

One organization per site or community; rights follow Keycloak subgroups of `openwisp` in realm `chat` (the client's `groups` mapper
sends full paths):

| Group | Effect at login |
|---|---|
| `/openwisp` | may log in, staff, no organization |
| `/openwisp/<org-slug>` | organization admin of `<org-slug>`, Django group Operator (device management) |
| `/openwisp/<org-slug>/admin` | the same, Django group Administrator |

Every organization membership is an organization admin (`is_admin`): OpenWISP shows a staff user only the organizations they manage, so
without it the user would see nothing. The Django groups are global, not per organization: Administrator only for a user who is
`/admin` in every organization they get, else Operator. Administrator on top of Operator adds adding, changing and deleting users,
organization users, CAs, certificates, VPNs, subnets, credentials, API keys and the organization settings (Operator has
read access to CAs, certificates, VPNs and Wi-Fi sessions and manages devices and templates), all within their organizations.

`oidc_gate.py` makes `OrganizationUser` and the two Django groups match the claim at every login and removes memberships that are
no longer in it. Not touched: superusers, organization owners, organizations that do not exist (created by
`ops/ffmuc-openwisp-site-orgs.sh` in the admin repo, not from the claim), and users already logged in until their next login.
A user who has left `openwisp` is refused (403) and loses memberships and both groups at that attempt (superusers and owners
excepted); sessions that are already open run until they expire.
A claim with bare group names (mapper `full.path` off) still opens the gate but syncs nothing: switch the mapper after this version runs.
Tests: `python3 -m unittest discover -s stacks/docker07/openwisp/tests`.

## First setup (admin, on docker07)

1. `mkdir -p /srv/docker/openwisp/{media,private,ssh}; chown -R 1001:0 /srv/docker/openwisp; chmod 700 /srv/docker/openwisp/ssh`
   (the images run as uid 1001; media, private files and the controller's SSH key are backed up with `/srv`).
2. Pillar `komodo-secrets/docker07.sls`, then `state.apply komodo-periphery`: `OPENWISP_DB_PASS`,
   `OPENWISP_DJANGO_SECRET_KEY`, `OPENWISP_REDIS_PASS`, `OPENWISP_INFLUXDB_PASS`, `OPENWISP_SMTP_PASSWORD`
   (same account as Mastodon's `MASTODON_SMTP_PASSWORD`), `OPENWISP_ADMIN_PASSWORD`, `OPENWISP_OIDC_CLIENT_SECRET`
   (client secret of the Keycloak client). Values as in `stacks/README.md`; alphanumeric for `OPENWISP_DB_PASS` and `OPENWISP_REDIS_PASS`.
3. Deploy; the first start migrates and creates the superuser `admin` with the password `admin`. Directly after:
   `docker compose -p openwisp --profile init run --rm admin-password` (in the stack directory with Komodo's `.env`) sets the password from `OPENWISP_ADMIN_PASSWORD`.
4. NetBox config context of docker07, `backup.dump_commands`:
   `"openwisp.dump": "docker exec openwisp-postgres-1 sh -c 'exec pg_dump -Fc -Z0 -U \"$POSTGRES_USER\" \"$POSTGRES_DB\"'"`.
   Postgres, Redis, InfluxDB and the static files are named volumes outside `/srv` (not in rustic): the dump is the
   database backup, InfluxDB is rebuildable (device data refills it).
5. DNS: `openwisp.ov.ffmuc.net` as for the other `ov` names.

## Hardening and exceptions (lab, 23.11.)

All containers: `cap_drop: ALL`, `no-new-privileges`. Exceptions:

- nginx: `cap_add` CHOWN, SETUID, SETGID (root master chowns the cache dirs and drops to the worker user; port 80 needs none).
- `read_only` with tmpfs: websocket, both Celery workers, Valkey (`user: 999:1000`), InfluxDB (root, no capability), Postgres.
  Not possible: dashboard, api and celerybeat (the entrypoint writes `uwsgi.ini` and `celerybeat-schedule` into the code
  directory) and nginx (the entrypoint renders `/etc/nginx`).
- The api and websocket images carry none of the `UWSGI_*`/`USE_OPENWISP_CELERY_*` defaults upstream passes in `.env`:
  they are set in `x-env-plain`.
- The settings file must take `INSTALLED_APPS` and `SOCIALACCOUNT_PROVIDERS` from `openwisp.settings` (it is imported with `import *`).
- Healthchecks: `celery inspect ping` against the own node, `pgrep` for celerybeat.
- At start the images fetch the public suffix list and geocode.arcgis.com (egress needed, failure only logs).
- The image scopes `SESSION_COOKIE_DOMAIN`/`CSRF_COOKIE_DOMAIN` to `.ffmuc.net`; the settings file sets them host-only.

## Names

`DASHBOARD_DOMAIN` and `API_DOMAIN` (stack environment, defaults `openwisp.ffmuc.net`, `openwisp-api.ffmuc.net`) feed
`DJANGO_ALLOWED_HOSTS`, CSRF/CORS origins and the OIDC redirect URI; the overlay name stays in `DJANGO_ALLOWED_HOSTS`,
the CSRF origins (`config/custom_django_settings.py`) and the Traefik rule.
`NGINX_TRUSTED_PROXIES` lists the webfrontends (HAProxy sets `X-Forwarded-For`); `OIDC_SERVER_URL` sets the Keycloak discovery URL.
Another dashboard name needs the redirect URI in the Keycloak client; `NGINX_ADMIN_ALLOW_NETWORK` restricts `/admin` if needed.

## Lab results

- Fresh start with the pinned images: migrations run, `admin-password` replaces `admin`/`admin`.
- Keycloak login (local Keycloak): `/accounts/oidc/keycloak/login/` -> callback `/accounts/oidc/keycloak/login/callback/`,
  django-allauth 65.19.7. The first login creates a user without rights (`is_staff` false, no organization).
  Any realm user can log in; the `groups` claim (mapper on the client) arrives in `extra_data`, a non-member gets none.
  Access for the group `openwisp` only: `config/oidc_gate.py`.
- Mail reaches the SMTP server as `no-reply@ffmuc.net` through the Celery email backend.
- Restore: `pg_dump` from step 4 into an empty PostGIS of the same image; row counts equal. The extension objects
  PostGIS creates itself give three harmless `pg_restore` errors (`schema "topology" already exists`).
- Idle memory (about 5 min): dashboard 190 MB, api 140 MB, websocket 165 MB, celery 380 MB, celery_monitoring 370 MB,
  celerybeat 155 MB, Postgres 60 MB, InfluxDB 15 MB, Valkey 6 MB, nginx 4 MB.

Updates: Renovate raises tag and digest of the four `openwisp/*` images and the databases; read the release notes
(migrations) and take a dump first.
