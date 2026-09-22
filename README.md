# FFMUC-SALT-PUBLIC Repo
This is the salt repo for Freifunk Munich

## Dependencies
This repo makes heavy use of Netbox based ext-pillar information especially config_contexts, services and ip information

Netbox is a hard dependency at *render* time: `_modules/site_prefixes.py`,
`_modules/extra_dns_entries.py` and `_modules/cfssl_certs.py` are called from
Jinja while states are being rendered. They fail closed - if Netbox cannot be
reached the render aborts and the highstate goes red, rather than quietly
producing a config with no prefixes or no DNS records.

## Sample config_context
```
{
    "docker": {
        "cfssl": {
            "container_dir": "/srv/docker/cfssl",
            "credentials": {
                "db_password": "password"
            },
            "mounts": [
                "/srv/docker/postgresql-cfssl/data",
                "/srv/docker/cfssl/data",
                "/srv/docker/postgresql-cfssl/data"
            ]
        },
        "openldap": {
            "container_dir": "/srv/docker/openldap",
            "credentials": {
                "admin_user": "password",
                "readonly_user": "password"
            },
            "mounts": [
                "/srv/docker/openldap/data",
                "/srv/docker/openldap/config",
                "/srv/docker/openldap/certs"
            ]
        },
        "zammad": {
            "container_dir": "/srv/docker/zammad-docker-compose",
            "git": "https://github.com/zammad/zammad-docker-compose.git",
            "mounts": [
                "/srv/docker/zammad-backup",
                "/srv/docker/zammad-data",
                "/srv/docker/elasticsearch-zammad/data",
                "/srv/docker/postgresql-zammad/data"
            ]
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
