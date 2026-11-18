###
# BGPalerter config (docker07)
# Rendered from salt://bgpalerter/config.yml.j2 to the path the Komodo stack docker07/bgpalerter mounts
# (/srv/docker/bgpalerter/volume -> /opt/bgpalerter/volume). The Mattermost webhook comes from pillar
# bgpalerter:mattermost_webhook (master: /srv/docker/salt/pillar/komodo-secrets/docker07.sls, never in Git).
# prefixes.yml and logs/ stay hand-managed. Rollback: restore config.yml from the .bak next to it, restart the container.
###

{%- if not salt['pillar.get']('bgpalerter:mattermost_webhook', '') %}
bgpalerter-config-missing:
  test.fail_without_changes:
    - name: "pillar bgpalerter:mattermost_webhook is missing"
{%- else %}
bgpalerter-config:
  file.managed:
    - name: /srv/docker/bgpalerter/volume/config.yml
    - source: salt://bgpalerter/config.yml.j2
    - template: jinja
    - user: root
    - group: root
    - mode: "0640"
    - show_changes: False
{%- endif %}
