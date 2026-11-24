# OpenWISP controller (docker07)

Lab stack after [docker-openwisp](https://github.com/openwisp/docker-openwisp) 26.09.5, for non-Gluon OpenWrt devices.
UI and API at `https://openwisp.ov.ffmuc.net` (overlay only, Traefik without `noc-auth`: the app logs in itself).
No public name yet: the device API (`openwisp-api.ffmuc.net`, HAProxy, Nebula rule) is phase 2.

- Off: RADIUS, OpenVPN (management VPN, `VPN_DOMAIN` empty), postfix (mail goes to `mail01.fnmuc.net:587` as
  `no-reply@ffmuc.net`), topology, firmware upgrader. On: monitoring with InfluxDB 1.8.
- Login: Keycloak realm `ffmuc`, client `openwisp`, only members of the group `openwisp`
  (`config/custom_django_settings.py`, django-allauth `openid_connect`; mounted into the image, no derived image needed).
  Start at `/accounts/oidc/keycloak/login/`; the login page has no provider button.
  New users have no rights: a superuser grants them an organization role.
- Break-glass: local superuser `admin` on `/admin/login/`.

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

`DASHBOARD_DOMAIN` and `API_DOMAIN` (stack environment, defaults `openwisp.ov.ffmuc.net`, `openwisp-api.ffmuc.net`) feed
`DJANGO_ALLOWED_HOSTS`, CSRF/CORS origins, the Traefik rule and the OIDC redirect URI; `OIDC_SERVER_URL` sets the Keycloak discovery URL.
Another dashboard name needs the redirect URI in the Keycloak client and, behind a proxy, `NGINX_TRUSTED_PROXIES`
(real client IP from `X-Forwarded-For`) and `NGINX_ADMIN_ALLOW_NETWORK` (restricts `/admin`) on nginx.

## Lab results

- Fresh start with the pinned images: migrations run, `admin-password` replaces `admin`/`admin`.
- Keycloak login (local Keycloak): `/accounts/oidc/keycloak/login/` -> callback `/accounts/oidc/keycloak/login/callback/`,
  django-allauth 65.19.7. The first login creates a user without rights (`is_staff` false, no organization).
  Any realm user can log in; the `groups` claim (mapper on the client) arrives in `extra_data`, a non-member gets none.
  Access for the group `openwisp` only is enforced in Keycloak.
- Mail reaches the SMTP server as `no-reply@ffmuc.net` through the Celery email backend.
- Restore: `pg_dump` from step 4 into an empty PostGIS of the same image; row counts equal. The extension objects
  PostGIS creates itself give three harmless `pg_restore` errors (`schema "topology" already exists`).
- Idle memory (about 5 min): dashboard 190 MB, api 140 MB, websocket 165 MB, celery 380 MB, celery_monitoring 370 MB,
  celerybeat 155 MB, Postgres 60 MB, InfluxDB 15 MB, Valkey 6 MB, nginx 4 MB.

Updates: Renovate raises tag and digest of the four `openwisp/*` images and the databases; read the release notes
(migrations) and take a dump first.
