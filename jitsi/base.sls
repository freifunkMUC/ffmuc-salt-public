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
