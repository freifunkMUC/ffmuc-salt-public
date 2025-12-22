# resolv - Manage /etc/resolv.conf

This Salt state manages DNS resolution configuration for all minions, with different strategies based on whether the machine runs a local DNS resolver.

## Features

- **Conditional DNS configuration**:
  - Machines with pdns-recursor or dnsdist: Static resolv.conf with anycast servers, systemd-resolved disabled
  - Other machines: systemd-resolved enabled with anycast servers configured
- **Site-aware anycast server priority**: Prefers local site's anycast servers first
- **Automatic detection**: Uses Netbox pillar data to detect if machine runs DNS resolver

## Implementation Details

### Machines with Local DNS Resolvers (pdns-recursor or dnsdist)

These machines get:
- `systemd-resolved` disabled
- Static `/etc/resolv.conf` pointing to anycast DNS servers
- `follow_symlinks: False` to remove any existing symlinks

Anycast servers (site-aware):
- **muc01**: 2001:678:ed0:f000::, 185.150.99.255 (primary), then vie01 servers
- **vie01**: 2001:678:e68:f000::, 5.1.66.255 (primary), then muc01 servers
- **Other sites**: All anycast servers with vie01 first

### Other Machines

These machines get:
- `systemd-resolved` enabled and running
- `/etc/resolv.conf` symlinked to `/run/systemd/resolve/stub-resolv.conf`
- `/etc/systemd/resolved.conf` configured with anycast servers

## Detection Logic

The state automatically detects if a machine should use local DNS resolver by checking:
1. Netbox services for `pdns-recursor`
2. Netbox tags for `dnsdist`

## Usage

The `resolv` state is applied to all minions via `top.sls`.

No manual configuration is needed - the state automatically adapts based on the machine's role and services.
