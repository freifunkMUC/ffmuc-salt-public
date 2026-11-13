###
# Keycloak ALTCHA registration provider (docker07)
# The Komodo stack docker07/keycloak mounts /srv/docker/keycloak/providers read-only at /opt/keycloak/providers; `kc.sh start`
# (not --optimized) picks the JAR up at the next boot. Apply this state BEFORE the stack is deployed and the flow is bound;
# after a version bump restart the stack (Komodo) so Keycloak loads the new JAR.
# Upstream: https://git.lacontrevoie.fr/lacontrevoie/keycloak-altcha (MIT, built against Keycloak 26.6.3). Version bump by hand:
# new URL and sha256 (no Renovate manager for Gitea releases), then test registration on the new Keycloak before it goes live.
###

{%- set altcha_version = '2.0.0' %}
{%- set altcha_sha256 = '78ccf6b9927b8100c5dcd1f1defd35eb86adf59a518652db5e11ca30fc70d559' %}

keycloak-providers-dir:
  file.directory:
    - name: /srv/docker/keycloak/providers
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True
    # an old JAR is removed after a version bump (files of other states in this directory are kept)
    - clean: True

keycloak-altcha-jar:
  file.managed:
    - name: /srv/docker/keycloak/providers/keycloak-altcha-{{ altcha_version }}.jar
    - source: https://git.lacontrevoie.fr/lacontrevoie/keycloak-altcha/releases/download/{{ altcha_version }}/keycloak-altcha-jar-with-dependencies.jar
    - source_hash: sha256={{ altcha_sha256 }}
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: keycloak-providers-dir
