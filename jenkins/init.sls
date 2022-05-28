#
# Jenkins
#
{% if salt['pillar.get']('netbox:role:name') %}
{%- set role = salt['pillar.get']('netbox:role:name') %}
{% else %}
{%- set role = salt['pillar.get']('netbox:device_role:name') %}
{% endif %}

{% if 'buildserver' in role %}
jenkins-repo-key:
  cmd.run:
    - name: "curl https://pkg.jenkins.io/debian/jenkins.io.key | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg"
    - creates: /usr/share/keyrings/jenkins-keyring.gpg

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
