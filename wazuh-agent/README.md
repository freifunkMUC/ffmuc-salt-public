# wazuh-agent

Installs the Wazuh agent and enrolls it at the manager (`stacks/docker07/wazuh`, Nebula only: 1514 events, 1515 enrollment).

- **Enablement:** NetBox tag `wazuh-agent` on the device (default off). Parker gateways (role `parker-gateway`, `pgw*`) are always skipped.
  The state is in the base set of `top.sls`, so the tag is the only switch. Removing the tag does not uninstall the agent.
- **Repo:** `packages.wazuh.com/4.x/apt`, signed-by `GPG-KEY-WAZUH.asc` in this directory (fingerprint
  `0DCFCA5547B19D2A6099506096B3EE5F29111145`, valid until 2027-05-16; replace the file when Wazuh rotates the key).
- **Version:** pinned to the manager version (`wazuh_version` in `init.sls`, apt pin priority 1001, so unattended-upgrades stays
  on it). Upgrade the manager stack first, then bump the version here.
- **Config:** only the `<client>` block of the packaged `/var/ossec/etc/ossec.conf` is replaced (manager `10.8.0.16`,
  tcp/1514, enrollment with `authorization_pass_path`); the agent name is the short minion id.
- **Log noise:** the packaged `journald` localfile gets a filter that drops `haproxy` (webfrontends; the access logs are in Graylog and
  flooded the agent queue, rule 203), and nginx `error.log` ignores the client-reset line `recv() failed (104 ...) while proxying`.
  The agent buffer (`client_buffer` queue_size) is raised from 5000 to 20000: the 12 h rootcheck scan bursts above 500 events/s and filled it (rule 202/203). All are `file.replace` on the packaged blocks (no-op when the block is absent). Manager side: `stacks/docker07/wazuh/config/local_rules.xml`.
- **Pillar** (master, not in Git): `wazuh:enrollment_password`, the same value as the manager's `WAZUH_AUTHD_PASS`
  (Komodo Periphery secret in `komodo-secrets/docker07.sls`). Example, `/srv/docker/salt/pillar/wazuh.sls` (`#!yaml`, 0640):

      wazuh:
        enrollment_password: <value>

  and in the pillar `top.sls`: `'not pgw*'` with `- match: compound` and `- wazuh` (a plain `not` target needs the compound matcher). Optional `wazuh:manager_address` (or NetBox context `wazuh.manager_address`) overrides the manager address; `*.meet.ffmuc.net` default to `10.111.0.118` (docker07 in `nebula-meet`), all others to `10.8.0.16`.
  With the tag set but the password missing the state fails with a clear message and changes nothing.
- **Nebula:** `nebula/files/config.yml.jinja` allows TCP 1514 and 1515 from all Nebula hosts on docker07; `nebula-meet/files/config.yml.jinja` allows them from the Jitsi groups (`jvb`, `jicofo`, `jigasi`) only. The compose stack binds both ports on docker07's `nebula0` and `nebula-meet` addresses.

Jitsi rollout (owner, in this order): `salt docker07.in.ffmuc.net state.apply nebula-meet test=True`, then real apply (docker07 runs `nebula-meet` but is not in `top.sls`, so only an explicit apply touches it; a firewall change rewrites the config and restarts only docker07's nebula-meet) -> Komodo redeploy `wazuh` -> tag and `state.apply wazuh-agent` on `jicofo03` -> check the agent -> the other Jitsi hosts one by one. Mind RAM on jvb12-14 (agent adds a few hundred MB).

Rollout: tag one host in NetBox, `salt <host> state.apply wazuh-agent test=True`, then apply and check the agent in the dashboard.
