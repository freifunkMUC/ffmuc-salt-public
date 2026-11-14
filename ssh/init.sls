#
# SSH configuration
#

{% set user_groups = salt['pillar.get']('netbox:config_context:ssh_user_keys') %}
{% set user_home = salt['pillar.get']('netbox:config_context:user_home') %}
{% set removed_users = salt['pillar.get']('netbox:config_context:ssh_removed_users', []) %}

# Install ssh server
ssh:
  pkg.installed:
    - name: 'openssh-server'
  service.running:
    - enable: True
    - reload: True


# Enforce pubkey auth (disable password auth) and reload server on config change
/etc/ssh/sshd_config:
  file.managed:
    - source:
      - salt://ssh/sshd_config
    - user: root
    - group: root
    - mode: "0644"
    - template: jinja
    - watch_in:
      - service: ssh

/etc/ssh/sshrc:
  file.managed:
    - source:
      - salt://ssh/sshrc
    - user: root
    - group: root
    - mode: "0644"

{% for group in user_groups|sort %}
{% for user in user_groups[group]|sort %}
  {% if user not in user_home %}
    {% set path = '/home/' ~ user %}
  {% else %}
    {% set path = user_home[user] %}
  {% endif %}

# Create Groups
{%- if 'system_users' not in group %}
group-{{ user }}:
  group.present:
      - name: {{ user }}
{% endif %}

# Create SSH User
ssh-{{ user }}:
  user.present:
    - name: {{ user }}
    - shell: /bin/bash
    - home: {{ path }}
    - createhome: True
    {%- if 'system_users' in group %}
    - groups:
      - nogroup
    - system: True
    {% else %}
    - usergroup: False
    - system: False
    {%- endif -%}
    {%- if 'admins' in group %}
    - groups:
      - sudo
    {%- endif %}
    {%- if 'system_users' not in group %}
    - require:
      - group: group-{{ user }}
    {% endif %}

# Create .ssh folder for user
{{ path }}/.ssh:
  file.directory:
    - user: {{ user }}
    - group: {{ user }}
    - mode: "0700"
    - require:
      - user: ssh-{{ user }}

# Create and fill users authorized_keys
{{ path }}/.ssh/authorized_keys:
  file.managed:
    - user: {{ user }}
    - group: {{ user }}
    - contents:
      - {{ user_groups[group][user]  }}
    - mode: "0644"
    - require:
      - file: {{ path }}/.ssh
{{ path }}/.ssh/authorized_keys2:
  file.absent

{% endfor %}{# for user #}
{% endfor %}{# for group #}


# Create /root/.ssh folder
/root/.ssh:
  file.directory:
    - user: root
    - group: root
    - mode: "0700"

# Generate /root/.ssh/authorized_keys
/root/.ssh/authorized_keys:
  file.managed:
    - source: salt://ssh/authorized_keys.tmpl
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /root/.ssh

/root/.ssh/authorized_keys2:
  file.absent

# Template account from the VM image, locked wherever it exists
lock-template-user-ffmuc:
  user.present:
    - name: ffmuc
    - password_lock: True
    # expired, so sshd refuses SSH keys too (password_lock alone does not)
    - expire: 1
    - createhome: False
    - onlyif: getent passwd ffmuc


# Leavers: accounts listed in NetBox config context ssh_removed_users are locked,
# lose keys and sudo; home data stays. Never creates or deletes accounts.
# An empty/failed NetBox pillar (no ssh_user_keys) skips this, so a broken pillar locks nobody.
{% set current_users = [] %}
{% for group in (user_groups or {}) %}
{% for u in user_groups[group] %}{% do current_users.append(u) %}{% endfor %}
{% endfor %}
{% set protected_users = ['root', 'ffmuc'] %}
{% if user_groups and removed_users %}
{% for user in removed_users|sort %}
{% if user in current_users %}

ssh-removed-user-conflict-{{ user }}:
  test.fail_without_changes:
    - name: "ssh_removed_users lists an account that is still in ssh_user_keys (ignored)"
{% elif user|regex_match('^[a-z_][a-z0-9_-]*$') and user not in protected_users %}
  {# home as the account has it (getent), falling back to user_home/default #}
  {% set path = (salt['user.info'](user) or {}).get('home') or (user_home or {}).get(user, '/home/' ~ user) %}

lock-removed-user-{{ user }}:
  user.present:
    - name: {{ user }}
    - password_lock: True
    # expired, so sshd refuses SSH keys too
    - expire: 1
    - createhome: False
    - onlyif: getent passwd {{ user }}

drop-sudo-removed-user-{{ user }}:
  cmd.run:
    - name: gpasswd -d {{ user }} sudo
    - onlyif: id -nG {{ user }} 2>/dev/null | tr ' ' '\n' | grep -qx sudo

{% for f in ['authorized_keys', 'authorized_keys2'] %}
{{ path }}/.ssh/{{ f }}-removed-{{ user }}:
  file.absent:
    - name: {{ path }}/.ssh/{{ f }}
{% endfor %}
{% endif %}
{% endfor %}
{% endif %}
