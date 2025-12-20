# resolv - Manage /etc/resolv.conf

This Salt state manages the `/etc/resolv.conf` file for DNS resolution configuration.

## Features

- Manages `/etc/resolv.conf` with configurable nameservers and search domains
- Disables `systemd-resolved` to prevent conflicts with static DNS configuration
- Supports pillar-based configuration for flexibility

## Configuration

The state uses pillar data from Netbox config context with sensible defaults:

### Nameservers

Default nameservers: `['1.1.1.1', '8.8.8.8']`

Override via pillar:
```yaml
netbox:
  config_context:
    nameservers:
      - 127.0.0.1  # Use local DNS resolver
      - 1.1.1.1    # Fallback to Cloudflare DNS
```

### Search Domains

Default search domain: `['ffmuc.net']`

Override via pillar:
```yaml
netbox:
  config_context:
    search_domains:
      - ffmuc.net
      - in.ffmuc.net
```

## Usage

The `resolv` state is applied to all minions via `top.sls`.

For machines running local DNS resolvers (e.g., pdns-recursor), configure them to use `127.0.0.1` as the primary nameserver via pillar data.
