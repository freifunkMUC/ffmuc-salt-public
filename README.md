# FFMUC-SALT-PUBLIC Repo
This is the salt repo for Freifunk Munich

## Dependencies
This repo makes heavy use of Netbox based ext-pillar information especially config_contexts, services and ip information

Netbox is a hard dependency at *render* time: `_modules/site_prefixes.py`,
`_modules/extra_dns_entries.py` and `_modules/cfssl_certs.py` are called from
Jinja while states are being rendered. They fail closed - if Netbox cannot be
reached the render aborts and the highstate goes red, rather than quietly
producing a config with no prefixes or no DNS records.

## Docker

The `docker` state installs the engine plus the `docker-compose-plugin`.
Compose stacks live in `docker-containers/`; see the README there for the
pattern and conventions. Use `docker compose` (v2) - the v1 `docker-compose`
binary is deliberately removed by the `docker` state.

## Sample config_context
```
{
    "docker": {
        "diun": {
            "enabled": true,
            "webhookURL": "https://hooks.slack.com/services/..."
        },
        "speedtest": {
            "enabled": false,
            "frontend_port": 80,
            "backend_port": 8082
        }
    },
    "roles": [
        "backup_client",
        "icinga2_client"
    ],
    "ssh_host_key": {
        "ssh_host_ecdsa_key": "",
        "ssh_host_ecdsa_key.pub": "",
        "ssh_host_ed25519_key": "",
        "ssh_host_ed25519_key.pub": "",
        "ssh_host_rsa_key": "",
        "ssh_host_rsa_key.pub": ""
    },
    "ssh_user_keys": {
        "admins": {
            "admin1": "ssh-rsa key-data"
        },
        "system_users": {},
        "users": {}
    },
    "user_home": {}
}
```

## Linting

CI runs `black`, `yamllint`, `salt-lint` and `shellcheck`. To run them locally:

```
black --check --diff .
yamllint -c .yamllint .
salt-lint -x 204,205 $(find . -name '*.sls' -o -name '*.jinja' -o -name '*.j2' -o -name '*.tmpl')
shellcheck $(grep -rl '^#!.*sh' --include='*.sh' .)
```
