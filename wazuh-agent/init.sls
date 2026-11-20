###
# Wazuh agent. Opt-in per host with the NetBox tag `wazuh-agent`; never on Parker gateways (pgw*).
# Enrollment password: pillar wazuh:enrollment_password (master: /srv/docker/salt/pillar/wazuh.sls, never in Git).
# Manager and port: stacks/docker07/wazuh. The agent must not move past the manager version (bump both together).
###

{#- Same version as the manager image in stacks/docker07/wazuh/compose.yaml #}
{%- set wazuh_version = '4.14.10' %}
{%- set manager = salt['pillar.get']('wazuh:manager_address', '10.8.0.16') %}
{%- set enabled = 'wazuh-agent' in salt['pillar.get']('netbox:tag_list', [])
      and salt['pillar.get']('netbox:role:name', '') != 'parker-gateway'
      and not grains.id.startswith('pgw') %}

{%- if enabled and not salt['pillar.get']('wazuh:enrollment_password', '') %}
wazuh-agent-config-missing:
  test.fail_without_changes:
    - name: "wazuh-agent enabled, but pillar wazuh:enrollment_password is missing"
{%- elif enabled %}

wazuh-repo-key:
  file.managed:
    - name: /usr/share/keyrings/wazuh-keyring.asc
    - source: salt://wazuh-agent/GPG-KEY-WAZUH.asc
    - mode: "0644"

wazuh-repo:
  pkgrepo.managed:
    - humanname: Wazuh
    - name: deb [arch={{ grains.osarch }} signed-by=/usr/share/keyrings/wazuh-keyring.asc] https://packages.wazuh.com/4.x/apt/ stable main
    - file: /etc/apt/sources.list.d/wazuh.list
    - clean_file: True
    - require:
      - file: wazuh-repo-key

# Pin so that unattended-upgrades and apt upgrade stay on the manager version
/etc/apt/preferences.d/wazuh-agent:
  file.managed:
    - contents: |
        Package: wazuh-agent
        Pin: version {{ wazuh_version }}-*
        Pin-Priority: 1001
    - mode: "0644"

wazuh-agent:
  pkg.installed:
    - version: {{ wazuh_version }}-1
    - require:
      - pkgrepo: wazuh-repo
      - file: /etc/apt/preferences.d/wazuh-agent

wazuh-agent-authd-pass:
  file.managed:
    - name: /var/ossec/etc/authd.pass
    - contents_pillar: wazuh:enrollment_password
    - user: root
    - group: wazuh
    - mode: "0640"
    - show_changes: False
    - require:
      - pkg: wazuh-agent

# Only the <client> block of the packaged ossec.conf is replaced; the rest stays as shipped
wazuh-agent-config:
  file.replace:
    - name: /var/ossec/etc/ossec.conf
    - pattern: '(?s)<client>.*?</client>'
    - repl: |-
        <client>
            <server>
              <address>{{ manager }}</address>
              <port>1514</port>
              <protocol>tcp</protocol>
            </server>
            <config-profile>{{ grains.os | lower }}, {{ grains.os | lower }}{{ grains.osrelease.split('.')[0] }}</config-profile>
            <notify_time>10</notify_time>
            <time-reconnect>60</time-reconnect>
            <auto_restart>yes</auto_restart>
            <crypto_method>aes</crypto_method>
            <enrollment>
              <enabled>yes</enabled>
              <agent_name>{{ grains.id.split('.')[0] }}</agent_name>
              <authorization_pass_path>etc/authd.pass</authorization_pass_path>
            </enrollment>
        </client>
    - count: 1
    - require:
      - pkg: wazuh-agent

wazuh-agent-service:
  service.running:
    - name: wazuh-agent
    - enable: True
    - require:
      - file: wazuh-agent-authd-pass
    - watch:
      - file: wazuh-agent-config
      - file: wazuh-agent-authd-pass
{%- endif %}
