{#- Site DNS64 address on every pgw of the site (anycast inside the site).
    The broker sends it as parker.sites.<site>.dns64 (stacks/docker0[4-7]/wgkex/wgkex.yaml).
    The nodes send DNS to it through the tunnel of the site, so the active pgw answers
    with its own pdns-recursor (dns64_prefix, pdns-recursor/recursor.conf).
    Own interface, not dummy0: BIRD announces the dummy0 addresses with eBGP and uses
    them as source address, iptables reads them from the grains. The kernel does not
    use a deprecated address (PreferredLifetime=0) as source for new connections.
    No BGP: BIRD exports only the addresses from NetBox (EXTERNAL6_OUT).
    Each site has its own /64 for Parker DNS64 (<site /48>:f064::/64, in NetBox).
    Do not assign the ::64 IP to an interface in NetBox: then it goes into eBGP. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') %}
{%- if 'parker-gateway' in role %}
{%- set site_dns64 = {
  'MUC01': '2001:678:ed0:f064::64',
  'VIE01': '2001:678:e68:f064::64',
} %}
{%- set site = salt['pillar.get']('netbox:site:name', '') %}
{%- set dns64 = salt['pillar.get']('netbox:config_context:parker:dns64', site_dns64.get(site, '')) %}
{%- if not dns64 %}
{{- raise('No DNS64 address for ' ~ grains.id ~ ' (site ' ~ site ~ '). Set parker.dns64 in the NetBox config context.') }}
{%- endif %}
include:
  - parker.systemd-networkd

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
        Address={{ dns64 }}/128
        PreferredLifetime=0
    - user: systemd-network
    - group: systemd-network
    - mode: "0644"
    - watch_in:
      - cmd: systemd-networkd-reload
{%- endif %}
