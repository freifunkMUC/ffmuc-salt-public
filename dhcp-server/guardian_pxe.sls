#
# PXE boot and unattended Ubuntu install from the guardians (see README).
# Opt-in by the NetBox config context `dhcp_guardian.pxe.enabled` (Kea must
# be enabled too). Legacy PXE gets netboot.xyz over TFTP. iPXE clients get
# boot.ipxe over HTTP: hosts in `install_hosts` install Ubuntu without
# questions, all other hosts get the netboot.xyz menu.
#
{%- from 'dhcp-server/pxe/map.jinja' import pxe with context %}
{%- from 'salt-minion/init.sls' import salt_version with context %}
{%- from 'nebula/map.jinja' import nebula with context %}
{%- if pxe.enabled %}
{%- set ubuntu_dir = pxe.root ~ '/ubuntu/' ~ pxe.release %}

guardian-pxe-packages:
  pkg.installed:
    - pkgs:
      - tftpd-hpa
      - nginx
      - libarchive-tools

/etc/modules-load.d/tftp.conf:
  file.managed:
    - contents: nf_conntrack_tftp

nf_conntrack_tftp:
  kmod.present:
    - require:
      - file: /etc/modules-load.d/tftp.conf

/etc/default/tftpd-hpa:
  file.managed:
    - source: salt://dhcp-server/pxe/tftpd-hpa.jinja
    - template: jinja
    - context:
        pxe: {{ pxe | json }}
    - require:
      - pkg: guardian-pxe-packages

/srv/tftp/netboot.xyz.kpxe:
  file.managed:
    - source: https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe
    - source_hash: sha256=c3704368f1a9bf45de3eb72df9ca06fabee1aaf268c96564fc6451e49510978d
    - makedirs: True
    - mode: "0644"

tftpd-hpa:
  service.running:
    - enable: True
    - watch:
      - file: /etc/default/tftpd-hpa
    - require:
      - file: /srv/tftp/netboot.xyz.kpxe

/etc/nginx/sites-enabled/default:
  file.absent:
    - require:
      - pkg: guardian-pxe-packages

/etc/nginx/conf.d/pxe.conf:
  file.managed:
    - source: salt://dhcp-server/pxe/nginx.conf.jinja
    - template: jinja
    - context:
        pxe: {{ pxe | json }}
    - require:
      - pkg: guardian-pxe-packages

guardian-pxe-nginx:
  service.running:
    - name: nginx
    - enable: True
    - reload: True
    - watch:
      - file: /etc/nginx/conf.d/pxe.conf
      - file: /etc/nginx/sites-enabled/default

{{ pxe.root }}/boot.ipxe:
  file.managed:
    - source: salt://dhcp-server/pxe/boot.ipxe.jinja
    - template: jinja
    - makedirs: True
    - context:
        pxe: {{ pxe | json }}

# The live-server ISO (about 3 GB) is downloaded once and checked. casper
# loads it with url=, kernel and initrd come from the same ISO.
guardian-pxe-ubuntu-iso:
  cmd.run:
    - name: >-
        mkdir -p {{ ubuntu_dir }} &&
        curl -fsSL -o {{ ubuntu_dir }}/{{ pxe.iso }}.tmp https://releases.ubuntu.com/{{ pxe.release }}/{{ pxe.iso }} &&
        echo '{{ pxe.iso_sha256 }}  {{ ubuntu_dir }}/{{ pxe.iso }}.tmp' | sha256sum -c --quiet &&
        mv {{ ubuntu_dir }}/{{ pxe.iso }}.tmp {{ ubuntu_dir }}/{{ pxe.iso }}
    - creates: {{ ubuntu_dir }}/{{ pxe.iso }}

guardian-pxe-ubuntu-kernel:
  cmd.run:
    - name: >-
        bsdtar -xf {{ ubuntu_dir }}/{{ pxe.iso }} -C {{ ubuntu_dir }} --strip-components 1 casper/vmlinuz casper/initrd &&
        chmod 0644 {{ ubuntu_dir }}/vmlinuz {{ ubuntu_dir }}/initrd
    - creates: {{ ubuntu_dir }}/initrd
    - require:
      - cmd: guardian-pxe-ubuntu-iso
      - pkg: guardian-pxe-packages

{#- Per-host install files. A host that leaves install_hosts loses its files
    (clean), so its next PXE boot shows the menu and does not reinstall. #}
{%- set admins = salt['pillar.get']('netbox:config_context:ssh_user_keys:admins', {}) %}
{%- set keys = [] %}
{%- for admin in admins | sort %}{% do keys.append('environment="SSH_USER=' ~ admin ~ '" ' ~ admins[admin]) %}{% endfor %}
{%- set netbox_api = salt['pillar.get']('netbox:config_context:netbox:api_url') %}
{%- set netbox_token = salt['config.get']('netbox:config_context:dhcp_guardian:pxe:netbox_token') %}
{#- Nebula for the new host: the package, the CA and the lighthouses of the
    guardian (public data only). The host makes its own key in the install. #}
{%- if pxe.install_hosts and not (nebula.enabled and nebula.lighthouses) %}
{{ raise('pxe: the guardian has no Nebula config, so a new host cannot reach the salt master') }}
{%- endif %}
{%- set ca = [] %}
{%- for f in nebula.pki.cas %}{% do ca.append(salt['cp.get_file_str']('salt://nebula/cert/' ~ f) | trim) %}{% endfor %}
{%- set nebula_boot = {
	'version': nebula.version,
	'sha256': nebula.packages[nebula.version]['amd64'],
	'ca': ca | join('\n') ~ '\n',
	'lighthouses': nebula.lighthouses,
	'interface': nebula.interface,
} %}

{%- for host in pxe.install_hosts | sort %}
{%- set vm = salt['netbox_vms.get_vm_install_data'](netbox_api, netbox_token, host) %}
{%- set boot_ifaces = [] %}
{%- for iface in vm.interfaces if vm.primary_ip4 and vm.primary_ip4 in iface.addresses %}{% do boot_ifaces.append(iface) %}{% endfor %}
{%- if not boot_ifaces or not boot_ifaces[0].mac %}
{{ raise('pxe: ' ~ host ~ ' has no mgmt interface with a MAC and its primary IPv4 in NetBox') }}
{%- endif %}
{%- set ipxe_name = boot_ifaces[0].mac | replace(':', '-') ~ '.ipxe' %}

{{ pxe.root }}/ipxe/{{ ipxe_name }}:
  file.managed:
    - source: salt://dhcp-server/pxe/host.ipxe.jinja
    - template: jinja
    - makedirs: True
    - context:
        pxe: {{ pxe | json }}
        host: {{ host }}
    - require_in:
      - file: {{ pxe.root }}/ipxe

{{ pxe.root }}/autoinstall/{{ host }}/user-data:
  file.managed:
    - source: salt://dhcp-server/pxe/user-data.jinja
    - template: jinja
    - makedirs: True
    - context:
        pxe: {{ pxe | json }}
        host: {{ host }}
        vm: {{ vm | json }}
        salt_version: "{{ salt_version }}"
        nebula: {{ nebula_boot | json }}
        keys: {{ (keys | join('\n') ~ '\n') | json }}
    - require_in:
      - file: {{ pxe.root }}/autoinstall

{{ pxe.root }}/autoinstall/{{ host }}/meta-data:
  file.managed:
    - contents: |
        instance-id: {{ host }}
        local-hostname: {{ host.split('.')[0] }}
    - require_in:
      - file: {{ pxe.root }}/autoinstall

{{ pxe.root }}/autoinstall/{{ host }}/vendor-data:
  file.managed:
    - contents: ""
    - require_in:
      - file: {{ pxe.root }}/autoinstall
{%- endfor %}

{{ pxe.root }}/ipxe:
  file.directory:
    - clean: True
    - makedirs: True

{{ pxe.root }}/autoinstall:
  file.directory:
    - clean: True
    - makedirs: True
{%- else %}

guardian-pxe-not-configured:
  test.nop:
    - name: no dhcp_guardian.pxe config context, PXE left as it is
{%- endif %}
