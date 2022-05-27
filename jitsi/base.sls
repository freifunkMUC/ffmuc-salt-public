jitsi-repo-key:
  cmd.run:
    - name: "curl https://download.jitsi.org/jitsi-key.gpg.key | sudo sh -c 'gpg --dearmor > /usr/share/keyrings/jitsi-keyring.gpg'"
    - creates: /usr/share/keyrings/jitsi-keyring.gpg

jitsi-repo:
  pkgrepo.managed:
    - humanname: Jitsi Repo
    - name: deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/
    - file: /etc/apt/sources.list.d/jitsi-stable.list
    - clean_file: True
    - require:
      - cmd: jitsi-repo-key
