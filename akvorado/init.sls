###
# akvorado SNMP credentials (docker07)
# config/outlet.yaml of the Komodo stack !includes this file; the community comes from pillar akvorado:snmp_community
# (master: /srv/docker/salt/pillar/komodo-secrets/docker07.sls, never in Git).
###

{%- set community = salt['pillar.get']('akvorado:snmp_community', '') %}
{%- if not community %}
akvorado-snmp-credentials-missing:
  test.fail_without_changes:
    - name: "pillar akvorado:snmp_community is missing"
{%- else %}
akvorado-snmp-credentials:
  file.managed:
    - name: /srv/docker/akvorado/snmp-credentials.yaml
    - user: root
    - group: root
    - mode: "0640"
    - show_changes: False
    - contents: |
        ---
        ::/0:
          communities: {{ community | yaml_dquote }}
{%- endif %}
