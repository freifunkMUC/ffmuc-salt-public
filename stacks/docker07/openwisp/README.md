# OpenWISP controller (docker07)

Lab stack after [docker-openwisp](https://github.com/openwisp/docker-openwisp) 26.09.5, for non-Gluon OpenWrt devices.
UI and API at `https://openwisp.ov.ffmuc.net` (overlay only, Traefik without `noc-auth`: the app logs in itself).
No public name yet: the device API (`openwisp-api.ffmuc.net`, HAProxy, Nebula rule) is phase 2.

- Off: RADIUS, OpenVPN (management VPN, `VPN_DOMAIN` empty), postfix (mail goes to `mail01.fnmuc.net:587` as
  `no-reply@ffmuc.net`), topology, firmware upgrader. On: monitoring with InfluxDB 1.8.
- Login: Keycloak realm `ffmuc`, client `openwisp`, only members of the group `openwisp`
  (`config/custom_django_settings.py`, django-allauth `openid_connect`; mounted into the image, no derived image).
  Start at `/accounts/oidc/keycloak/login/`; the login page has no provider button.
  New users have no rights: a superuser grants them an organization role.
- Break-glass: local superuser `admin` on `/admin/login/`.

## First setup (admin, on docker07)

1. `mkdir -p /srv/docker/openwisp/{media,private,ssh}; chown -R 1001:0 /srv/docker/openwisp; chmod 700 /srv/docker/openwisp/ssh`
   (the images run as uid 1001; media, private files and the controller's SSH key are backed up with `/srv`).
2. Pillar `komodo-secrets/docker07.sls`, then `state.apply komodo-periphery`: `OPENWISP_DB_PASS`,
   `OPENWISP_DJANGO_SECRET_KEY`, `OPENWISP_REDIS_PASS`, `OPENWISP_INFLUXDB_PASS`, `OPENWISP_SMTP_PASSWORD`
   (same account as Mastodon's `MASTODON_SMTP_PASSWORD`), `OPENWISP_ADMIN_PASSWORD`, `OPENWISP_OIDC_CLIENT_SECRET`
   (client secret of the Keycloak client). Values as in `stacks/README.md`.
3. Deploy; the first start migrates and creates the superuser `admin` with the password `admin`. Directly after:
   `docker compose --profile init run --rm admin-password` sets the password from `OPENWISP_ADMIN_PASSWORD`.
4. NetBox config context of docker07, `backup.dump_commands`:
   `"openwisp.dump": "docker exec openwisp-postgres-1 sh -c 'exec pg_dump -Fc -Z0 -U \"$POSTGRES_USER\" \"$POSTGRES_DB\"'"`.
   Postgres, Redis, InfluxDB and the static files are named volumes outside `/srv` (not in rustic): the dump is the
   database backup, InfluxDB is rebuildable (device data refills it).
5. DNS: `openwisp.ov.ffmuc.net` as for the other `ov` names.

## Not yet tested (phase 1 of the plan)

- `cap_drop: ALL` per container: nginx (capability list), InfluxDB and Valkey run as root with a small `cap_add`; `read_only` and
  `user:` for the app images (uid 1001 already) are left out until tested. Healthchecks of the Celery services are missing.
- allauth `openid_connect` in the image (django-allauth below 65.20), callback
  `https://openwisp.ov.ffmuc.net/accounts/oidc/keycloak/login/callback/`, creation of the user on the first login.
- A derived image (`FROM` the pinned one) is only needed if the settings file turns out not to be enough.

Updates: Renovate raises tag and digest of the four `openwisp/*` images and the databases; read the release notes
(migrations) and take a dump first.
