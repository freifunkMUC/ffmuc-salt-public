# FFMUC-SALT-PUBLIC Repo
This is the salt repo for Freifunk Munich

## Dependencies
This repo makes heavy use of Netbox based ext-pillar information especially config_contexts, services and ip information

## Sample config_context
```
{
    "mine_functions": {
        "minion_external_ip6": [
            {
                "mine_function": "network.ip_addrs6"
            },
            {
                "cidr": "2001:678:e68:ff00::/64"
            }
        ]
    },
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

**Note:** The `minion_external_ip6` mine function uses the `cidr` parameter to exclude site-internal IPv6 addresses from the external IP list:
- For site ID 18: use `2001:678:e68:ff00::/64`
- For other sites: use `2001:678:ed0:ff00::/64`

This configuration should be set per-site in NetBox's config_context to ensure Nebula-over-IPv6 correctly identifies external addresses.
