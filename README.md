# FFMUC-SALT-PUBLIC Repo
This is the salt repo for Freifunk Munich

## Dependencies
This repo makes heavy use of Netbox based ext-pillar information especially config_contexts, services and ip information

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
