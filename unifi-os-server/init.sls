{#- UniFi OS Server (Ubiquiti) in rootful Podman on unifi-os. First install only: afterwards UniFi OS updates itself (uosserver-updater);
    the Network app's auto-update is a UI step (Settings, Control Plane, Updates), nothing here can set it. Back up first, then update by hand.
    Latest: https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~linux-x64 #}
{%- set uos_url = "https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64" %}
{%- set uos_hash = "f6111e9396a42c74016f5dde9b01fbef486a6fe69efe137935e6e38b7c22f94d" %}
{%- set swap_mb = 2048 %}
{%- set installed = "test -x /usr/local/bin/uosserver" %}

unifi-os-server-packages:
  pkg.installed:
    - pkgs:
      - podman
      - slirp4netns
      - passt
      - uidmap

# Ubiquiti asks for 2 GB swap; the PXE install has only 1 GB (lv_swap)
unifi-os-server-swapfile:
  cmd.run:
    - name: fallocate -l {{ swap_mb }}M /swapfile.new && chmod 600 /swapfile.new && mkswap /swapfile.new && mv /swapfile.new /swapfile
    - creates: /swapfile

# persist: true writes the fstab line and runs swapon
/swapfile:
  mount.swap:
    - persist: True
    - require:
        - cmd: unifi-os-server-swapfile

unifi-os-server-installer:
  file.managed:
    - name: /var/tmp/unifi-os-server-installer
    - source: {{ uos_url }}
    - source_hash: sha256={{ uos_hash }}
    - mode: "0700"
    - unless: {{ installed }}

# asks once "Proceed? (y/N)", there is no unattended flag
unifi-os-server-install:
  cmd.run:
    - name: printf 'y\n' | /var/tmp/unifi-os-server-installer
    - shell: /bin/bash
    - creates: /usr/local/bin/uosserver
    - require:
        - pkg: unifi-os-server-packages
        - mount: /swapfile
        - file: unifi-os-server-installer

unifi-os-server-installer-absent:
  file.absent:
    - name: /var/tmp/unifi-os-server-installer
    - require:
        - cmd: unifi-os-server-install

{%- for unit in ["uosserver", "uosserver-updater"] %}

{{ unit }}:
  service.running:
    - enable: True
    - require:
        - cmd: unifi-os-server-install
{%- endfor %}

# UniFi OS sees only the webfrontends (nginx/domains/unifi.ffmuc.net.conf) and limits failed logins per source IP, so one
# bad client locked everybody out: its nginx (realip built in, includes upstream-*.conf) trusts their X-Forwarded-For.
# UniFi OS empties config/http on every start, so a timer puts the file back (and drops it again if nginx -t fails).
{%- set proxies = salt['mine.get']('webfrontend0*', 'minion_overlay_address', tgt_type='glob') %}
/etc/uosserver-realip.conf:
  file.managed:
    - mode: "0644"
    - contents: |
        # Salt (unifi-os-server): X-Forwarded-For only from the webfrontends
{%- for minion, address in proxies | dictsort if address %}
        set_real_ip_from {{ address | regex_replace('/\d+$', '') }};
{%- endfor %}
        real_ip_header X-Forwarded-For;
        real_ip_recursive on;

/usr/local/sbin/uos-realip-sync:
  file.managed:
    - mode: "0755"
    - contents: |
        #!/bin/sh
        # Salt (unifi-os-server): keep /etc/uosserver-realip.conf in UniFi OS's nginx (runs as uosserver)
        set -eu
        cd /tmp
        src=/etc/uosserver-realip.conf; c=/data/unifi-core/config/http/upstream-reverse-proxy.conf
        dst=/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data/unifi-core/config/http/upstream-reverse-proxy.conf
        podman exec uosserver test -d /data/unifi-core/config/http || exit 0
        cmp -s "$src" "$dst" && exit 0
        cp "$src" "$dst.tmp" && mv "$dst.tmp" "$dst"
        if podman exec uosserver nginx -t 2>/dev/null; then podman exec uosserver nginx -s reload; echo "realip config installed"
        else rm -f "$dst"; podman exec uosserver nginx -s reload || true; echo "nginx -t failed, realip config removed" >&2; exit 1; fi

/etc/systemd/system/uos-realip-sync.service:
  file.managed:
    - contents: |
        [Unit]
        Description=Keep the real-IP config in UniFi OS's nginx (Salt unifi-os-server)
        After=uosserver.service
        [Service]
        Type=oneshot
        User=uosserver
        Environment=XDG_RUNTIME_DIR=/run/user/%U
        ExecStart=/usr/local/sbin/uos-realip-sync

/etc/systemd/system/uos-realip-sync.timer:
  file.managed:
    - contents: |
        [Unit]
        Description=Keep the real-IP config in UniFi OS's nginx
        [Timer]
        OnBootSec=3min
        OnUnitActiveSec=2min
        [Install]
        WantedBy=timers.target

uos-realip-sync.timer:
  service.running:
    - enable: True
    - require:
        - service: uosserver
        - file: /usr/local/sbin/uos-realip-sync
        - file: /etc/uosserver-realip.conf
    - watch:
        - file: /etc/systemd/system/uos-realip-sync.service
        - file: /etc/systemd/system/uos-realip-sync.timer

uos-realip-sync-now:
  cmd.run:
    - name: systemctl start uos-realip-sync.service
    - onchanges:
        - file: /etc/uosserver-realip.conf
        - file: /usr/local/sbin/uos-realip-sync
    - require:
        - service: uos-realip-sync.timer
