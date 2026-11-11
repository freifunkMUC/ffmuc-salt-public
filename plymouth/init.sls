#
# plymouth
#
# The webfrontends are headless VMs. On reboot, plymouth-reboot.service can hang
# for about 7 minutes (start-post timeout, then SIGKILL) after all other services
# have stopped. Mask the plymouth shutdown units so a reboot does not wait for it.
#

{%- for unit in ['plymouth-reboot', 'plymouth-poweroff', 'plymouth-halt', 'plymouth-kexec'] %}
{{ unit }}-masked:
  service.masked:
    - name: {{ unit }}.service
{%- endfor %}
