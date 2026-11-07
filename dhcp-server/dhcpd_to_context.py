#!/usr/bin/env python3
"""Turn a guardian's dhcpd.conf into the NetBox config context `dhcp_guardian`.

Reads the simple, flat dhcpd.conf the guardians have (global domain-name,
subnet blocks with one pool each, host blocks) from a file or stdin and
prints the JSON for the Salt state `dhcp-server.guardian`.

    ssh guardian-vie01 sudo cat /etc/dhcp/dhcpd.conf | dhcpd_to_context.py --interfaces eth0

The output contains the client reservations (MAC addresses): do not paste it
into a PR, ticket or chat, only into NetBox. `--summary` prints counts only.
"""
import argparse
import ipaddress
import json
import re
import sys


def _blocks(text):
    """Yield (header, body) of top level `header { body }` blocks."""
    depth, start, head_start = 0, 0, 0
    for i, ch in enumerate(text):
        if ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                yield text[head_start:start].strip().split(';')[-1].strip(), text[start + 1:i]
                head_start = i + 1


def parse(text, interfaces, valid_lifetime=None):
    text = re.sub(r'#.*', '', text)
    out = {'enabled': True, 'interfaces': interfaces, 'subnets': []}
    top = re.sub(r'(?s)\{.*?\}', '', text)
    m = re.search(r'option\s+domain-name\s+"([^"]*)"', top)
    if m:
        out['domain_name'] = m.group(1)
    lifetimes, hosts = set(), []
    for head, body in _blocks(text):
        words = head.split()
        if words[:1] == ['subnet']:
            net = ipaddress.ip_network(f'{words[1]}/{words[3]}')
            sub = {'subnet': str(net)}
            for key, pat in (('routers', r'option\s+routers\s+([^;]+);'),
                             ('dns', r'option\s+domain-name-servers\s+([^;]+);'),
                             ('next_server', r'next-server\s+([^;]+);'),
                             ('boot_file', r'filename\s+"([^"]*)";')):
                m = re.search(pat, body)
                if m:
                    sub[key] = re.sub(r'\s+', '', m.group(1)) if key in ('routers', 'dns') else m.group(1).strip()
            m = re.search(r'range\s+(\S+)\s+(\S+);', body)
            sub['pool'] = f'{m.group(1)} - {m.group(2)}'
            for key in ('default-lease-time', 'max-lease-time'):
                for v in re.findall(key + r'\s+(\d+);', body):
                    lifetimes.add((key, int(v)))
            out['subnets'].append(sub)
        elif words[:1] == ['host']:
            mac = re.search(r'hardware\s+ethernet\s+([0-9a-fA-F:]+);', body)
            ip = re.search(r'fixed-address\s+([\d.]+);', body)
            name = re.search(r'option\s+host-name\s+"([^"]*)"', body)
            res = {'mac': mac.group(1).lower(), 'ip': ip.group(1)}
            res['hostname'] = name.group(1) if name else words[1]
            hosts.append(res)
    for res in hosts:
        for sub in out['subnets']:
            if ipaddress.ip_address(res['ip']) in ipaddress.ip_network(sub['subnet']):
                sub.setdefault('reservations', []).append(res)
                break
        else:
            raise SystemExit(f"reservation {res['ip']} fits no subnet")
    for key, name in (('default-lease-time', 'valid_lifetime'), ('max-lease-time', 'max_valid_lifetime')):
        vals = {v for k, v in lifetimes if k == key}
        if len(vals) > 1:
            raise SystemExit(f'different {key} per pool: {sorted(vals)}')
        if vals:
            out[name] = vals.pop()
    if valid_lifetime:
        out['valid_lifetime'] = valid_lifetime
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('file', nargs='?', default='-')
    ap.add_argument('--interfaces', required=True, help='comma separated, as in /etc/default/isc-dhcp-server')
    ap.add_argument('--summary', action='store_true', help='counts only, no MAC addresses')
    args = ap.parse_args()
    text = sys.stdin.read() if args.file == '-' else open(args.file).read()
    ctx = parse(text, [i for i in args.interfaces.split(',') if i])
    if args.summary:
        print(json.dumps({'subnets': len(ctx['subnets']),
                          'reservations': sum(len(s.get('reservations', [])) for s in ctx['subnets']),
                          'interfaces': ctx['interfaces']}))
    else:
        print(json.dumps({'dhcp_guardian': ctx}, indent=2))


if __name__ == '__main__':
    main()
