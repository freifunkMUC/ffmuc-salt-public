#
# plymouth
#
# Our hosts are headless. On reboot, plymouth-reboot.service can hang for
# several minutes (start-post timeout, then SIGKILL) after all other services
# have stopped. Seen on webfrontend03 (7 min) and gw05 (3 min).
# Mask the plymouth shutdown units so a reboot does not wait for it.
#

{%- if grains.get('init') == 'systemd' and salt['pkg.version']('plymouth') %}
{%- for unit in ['plymouth-reboot', 'plymouth-poweroff', 'plymouth-halt', 'plymouth-kexec'] %}
{{ unit }}-masked:
  service.masked:
    - name: {{ unit }}.service
{%- endfor %}
{%- endif %}
