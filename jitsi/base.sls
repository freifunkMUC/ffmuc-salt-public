jitsi-repo-key:
  cmd.run:
    - name: "wget https://download.jitsi.org/jitsi-key.gpg.key -qO - | apt-key add -"
    - unless: 'gpg2 /etc/apt/trusted.gpg | grep FFD65A0DA2BEBDEB73D44C8BB4D2D216F1FD7806'

jitsi-repo:
  pkgrepo.managed:
    - humanname: Jitsi Repo
    - name: deb https://download.jitsi.org stable/
    - file: /etc/apt/sources.list.d/jitsi-stable.list
    - clean_file: True
