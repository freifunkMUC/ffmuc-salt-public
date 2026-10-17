jitsi-repo-key:
  cmd.run:
    - name: "curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/jitsi-keyring.gpg.tmp && mv /usr/share/keyrings/jitsi-keyring.gpg.tmp /usr/share/keyrings/jitsi-keyring.gpg"
    - creates: /usr/share/keyrings/jitsi-keyring.gpg

jitsi-repo:
  pkgrepo.managed:
    - humanname: Jitsi Repo
    - name: deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/
    - file: /etc/apt/sources.list.d/jitsi-stable.list
    - clean_file: True
    - require:
      - cmd: jitsi-repo-key

# jicofo >= 1.0-1100, jvb >= 2.3-300 and jigasi >= 1.1-400 require Java 17+
{#- trixie no longer ships openjdk-17; keep the state ID so existing requires keep working #}
{%- set java_ver = '21' if (grains.os == 'Debian' and grains.osmajorrelease | int >= 13) else '17' %}
jitsi-java17:
  pkg.installed:
    - name: openjdk-{{ java_ver }}-jre-headless
  cmd.run:
    - name: update-alternatives --set java /usr/lib/jvm/java-{{ java_ver }}-openjdk-{{ grains['osarch'] }}/bin/java
    - unless: test "$(readlink -f /etc/alternatives/java)" = /usr/lib/jvm/java-{{ java_ver }}-openjdk-{{ grains['osarch'] }}/bin/java
    - require:
      - pkg: jitsi-java17
