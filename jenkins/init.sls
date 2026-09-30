#
# Jenkins
#
{#- Default to '' rather than to the same lookup again: an unset role made
    this None, and `'...' in None` aborts the render with a TypeError. #}
{%- set role = salt['pillar.get']('netbox:role:name', '') or '' %}

{% if 'buildserver' in role %}
jenkins-repo-key:
  cmd.run:
    - name: "curl -fsSL https://pkg.jenkins.io/debian/jenkins.io-2026.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg.tmp && mv /usr/share/keyrings/jenkins-keyring.gpg.tmp /usr/share/keyrings/jenkins-keyring.gpg"
    # check the fingerprint instead of 'creates': Jenkins rotates the key and
    # an existing file would otherwise keep the expired one forever
    - unless: gpg --show-keys --with-colons /usr/share/keyrings/jenkins-keyring.gpg 2>/dev/null | grep -q '^fpr:.*:5E386EADB55F01504CAE8BCF7198F4B714ABFC68:'

jenkins:
  pkgrepo.managed:
    - comments:
      - "# Jenkins APT repo"
    - human_name: Jenkins repository
    - name: deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian binary/
    - file: /etc/apt/sources.list.d/pkg_jenkins_io_debian.list
    - clean_file: True
    - require:
      - cmd: jenkins-repo-key
    - require_in:
      - pkg: jenkins

  pkg.latest:
    - name: jenkins
{% endif %}
