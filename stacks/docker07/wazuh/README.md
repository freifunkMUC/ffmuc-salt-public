# Wazuh manager (docker07)

Single-node Wazuh 4.14 (manager, indexer, dashboard), after upstream
[wazuh-docker](https://github.com/wazuh/wazuh-docker) v4.14.10 `single-node`.
Agents will be rolled out by a Salt state `wazuh-agent` (follow-up PR, together with the Nebula rule).

- Dashboard `https://wazuh.ov.ffmuc.net` (internal only: Nebula and internal VLAN, docker07 has no public address), Traefik without `noc-auth`: the dashboard logs in itself,
  by OIDC against Keycloak realm `noc` (group Admin, TOTP), or as `admin` (basic auth, break-glass).
- Agents connect to `10.8.0.16:1514` and enroll on `:1515` (Nebula only; the Nebula
  firewall rule for 1514/1515 is part of the follow-up). The API (55000) and the indexer (9200) are not published.
- Alerts of level 10 and above go to Mattermost (Wazuh's `slack` integration, incoming webhook). No active response.
- `config/local_rules.xml` (copied into `etc/rules` at every start, redeploy to change): level 0 for the nagios/telegraf
  sudo checks on the vm-hosts and gateways (`100100`/`100101`) and the nameless-uid sudo PAM session lines (`100102`/`100103`;
  other sudo use and named users still alert), the nginx client reset on the gateways (`100110`), and 404 scanner bursts of
  `31151` at level 6 (`100120`, dashboard only, below the Mattermost threshold). Test: `wazuh-logtest`.
- Retention 90 days (alert, monitoring and statistics indices). Indexer data is not backed up (`.nobackup`);
  manager config, rules and agent keys in `/srv/docker/wazuh/manager/etc` are.

## First setup (admin, on docker07)

1. Logical volume for the indexer, 150 GiB (sizing: 100-150 GiB for about 40 agents at 90 days), mounted at
   `/srv/docker/wazuh/indexer`, owned by `1000:1000`. Done 20.11.2026 on its own disk: LV `raid10-vms/docker07_wazuh`
   on vm-host02, attached live as `sdb` (virtio-scsi), VG `vg_wazuh`, LV `lv_indexer`, ext4 by UUID in fstab. Then:
   `mkdir -p /srv/docker/wazuh/{certs,dashboard/config,dashboard/custom,manager,indexer/data}; touch /srv/docker/wazuh/indexer/.nobackup`
   and `chown 1000:1000 /srv/docker/wazuh; chown -R 1000:1000 /srv/docker/wazuh/{dashboard,indexer}; chmod 700 /srv/docker/wazuh/dashboard/config`
   (`init-users` writes as 1000 into `/srv/docker/wazuh`; `wazuh.yml` holds the API password).
2. Pillar `komodo-secrets/docker07.sls`: the five names from `stacks/README.md`, then `state.apply komodo-periphery`.
   Passwords: letters, digits, `.` and `-` only (filebeat and the API user take them through `sed`), with upper
   case, lower case, a digit and a symbol, 16-64 characters. `WAZUH_AUTHD_PASS` the same, and the same value as
   `wazuh:enrollment_password` in the agent pillar. `WAZUH_MATTERMOST_HOOK_URL` is an incoming webhook of the
   alert channel (Mattermost, Integrations). At every start the manager writes
   `WAZUH_AUTHD_PASS` to `/srv/docker/wazuh/manager/etc/authd.pass` (`root:wazuh`, 0640, `entrypoint-scripts/10-secrets.sh`).
3. Resource Sync (the stack appears), then Komodo `RunStackService` (Komodo writes `.env`, which every `${VAR:?}`
   needs, also for these one-off services; naming a service activates its profile):
   - `generator` (downloads the certificate tool from packages.wazuh.com, writes CA and node certificates to
     `/srv/docker/wazuh/certs`), then `chown -R 1000:1000 /srv/docker/wazuh/certs; chmod 640 /srv/docker/wazuh/certs/*.pem`.
   - `init-users` (writes `/srv/docker/wazuh/internal_users.yml`; must exist before the deploy, else Docker
     creates a directory in its place).
4. Deploy the stack in Komodo. The first start initialises the security index from `internal_users.yml`; the manager
   needs the indexer to be healthy first (a few minutes).
5. Retention: `RunStackService` `ism` once the indexer is up (idempotent; a rerun reports the indices that already
   have the policy and fails only on other errors).
6. Mattermost (channel `noc-monitoring`, webhook user name `wazuh`): `docker exec <manager> /var/ossec/bin/wazuh-control status | grep integratord`, then a test alert
   (level 10 or above, e.g. a `wazuh-logtest`-matched line written to a monitored log) must reach the channel.
7. Agents and Nebula rule: follow-up PR.

## Changing a password

Pillar, `state.apply komodo-periphery`, redeploy. The indexer users additionally need `init-users` and then
`securityadmin` on the running indexer (the file is read only when the security index is created):
`docker exec -e JAVA_HOME=/usr/share/wazuh-indexer/jdk wazuh-wazuh.indexer-1 bash -c '/usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh -cd /usr/share/wazuh-indexer/config/opensearch-security -icl -nhnv -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem -cert /usr/share/wazuh-indexer/config/certs/admin.pem -key /usr/share/wazuh-indexer/config/certs/admin-key.pem'`
(the API user is created from the environment at every start; `wazuh.yml` of the dashboard is written once and
must be edited in `/srv/docker/wazuh/dashboard/config`).

## Login (OIDC)

Keycloak admin, realm `noc`, create:
- Client `wazuh`: OpenID Connect, confidential (client authentication on), standard flow only, PKCE not needed.
  Root/home URL and valid redirect URI `https://wazuh.ov.ffmuc.net/*` (the plugin uses `/auth/openid/login`), web origin `https://wazuh.ov.ffmuc.net`.
- Mapper "User Realm Role" (or Group Membership, full path off) on the client, token claim name `roles`, add to ID token,
  access token and userinfo, claim JSON type String, multivalued. Members of the LDAP group `Admin` must carry the
  value `Admin` there (realm role `Admin` mapped from the group, as for `oauth2-proxy`). `Admin` maps to `all_access`
  (`config/security-roles_mapping.yml`). Realm `noc` admits only that group, so there is no read-only role.
- Client secret into the pillar as `WAZUH_OIDC_CLIENT_SECRET` (`komodo-secrets/docker07.sls`), `state.apply komodo-periphery`.

Files: `config/security-config.yml` (`openid_auth_domain`) and `config/security-roles_mapping.yml` are mounted into the
indexer but read only by `securityadmin` (command above, `-cd` already covers them), the dashboard settings are at the end of
`config/opensearch_dashboards.yml`, the client secret goes into the keystore at start (`entrypoint-scripts/dashboard.sh`).

Order: pillar and Keycloak client first, then merge, Resource Sync, `securityadmin`, redeploy the stack. Then test the
OIDC login and the `admin` login in a private window. If OIDC fails, `admin` (basic auth) still works; rollback: previous
commit and `securityadmin` (the old `config.yml` is the image default).

## Not in this directory

- Rollback: `docker compose -p wazuh down`, data stays.
