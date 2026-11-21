{#- Site DNS64 address on every pgw of the site (anycast inside the site).
    The broker sends it as parker.sites.<site>.dns64 (stacks/docker0[4-7]/wgkex/wgkex.yaml).
    The nodes send DNS to it through the tunnel of the site, so the active pgw answers
    with its own pdns-recursor (dns64_prefix, pdns-recursor/recursor.conf).
    The address comes from the NetBox interface "dns64" of the pgw: one IPv6 /128,
    role anycast, from the Parker DNS64 /64 of the site (<site /48>:f064::/64).
    Own interface, not dummy0: BIRD announces the dummy* addresses with eBGP and uses
    dummy0 as source address, iptables reads dummy0 from the grains.
    parker/systemd-networkd skips "dns64", so only this state writes its files.
    The kernel does not use a deprecated address (PreferredLifetime=0) as source
    for new connections. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') %}
{%- if 'parker-gateway' in role %}
{%- set addresses = salt['pillar.get']('netbox:interfaces:dns64:ipaddresses', []) | map(attribute='address') | select('match', '.*:.*/128$') | list %}
{%- if addresses | length != 1 %}
{{- raise('NetBox interface dns64 of ' ~ grains.id ~ ' must have exactly one IPv6 /128 (the site DNS64 address), found: ' ~ addresses | join(', ')) }}
{%- endif %}
{%- set dns64 = addresses[0] %}
include:
  - parker.systemd-networkd

# Old main branch: the generic loop wrote this file for a NetBox interface dns64.
/etc/systemd/network/10-dns64.network:
  file.absent:
    - watch_in:
      - cmd: systemd-networkd-reload

/etc/systemd/network/20-dns64.netdev:
  file.managed:
    - contents: |
        # Salt managed (parker/dns64)
        [NetDev]
        Name=dns64
        Kind=dummy
    - user: systemd-network
    - group: systemd-network
    - mode: "0644"
    - watch_in:
      - cmd: systemd-networkd-reload

/etc/systemd/network/20-dns64.network:
  file.managed:
    - contents: |
        # Salt managed (parker/dns64)
        # Site DNS64 address, the same on all pgws of the site. Not in BGP.
        [Match]
        Name=dns64

        [Network]
        IPv6AcceptRA=no
        LinkLocalAddressing=no

        [Address]
        Address={{ dns64 }}
        PreferredLifetime=0
    - user: systemd-network
    - group: systemd-network
    - mode: "0644"
    - watch_in:
      - cmd: systemd-networkd-reload
{%- endif %}
