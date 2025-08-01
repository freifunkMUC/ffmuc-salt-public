jool-packages:
  pkg.installed:
    - names:
      - jool-dkms
      - jool-tools

jool-config:
  file.managed:
    - source: salt://parker/plat/jool.conf.j2
    - name: /etc/jool/jool.conf
    - mode: "0644"
    - makedirs: True
    - template: jinja
    - context:
        {#- TODO: consider a separate public IPv4 address #}
        nat64_ipv4: 10.80.64.1 {# {{ salt['pillar.get']('netbox:config_context:network:nat64_ipv4', False) }} #}
    - require:
      - pkg: jool-packages

jool-script:
  file.managed:
    - source: salt://parker/plat/setup-jool.sh.j2
    - name: /usr/local/sbin/setup-jool.sh
    - mode: "0755"
    - template: jinja
    - context:
        {#- TODO: consider a separate public IPv4 address #}
        nat64_ipv6: fd00::64:64 {# {{ salt['pillar.get']('netbox:config_context:network:nat64_ipv6', False) }} #}
        nat64_ipv4: 10.80.64.1 {# {{ salt['pillar.get']('netbox:config_context:network:nat64_ipv4', False) }} #}

jool-unit:
  file.managed:
    - source: salt://parker/plat/jool.service
    - name: /etc/systemd/system/jool.service
    - mode: "0644"

jool-service:
  service.running:
    - name: jool
    - enable: True
    - reload: True
    - watch:
      - file: jool-config
      - file: jool-script
      - file: jool-unit
    - require:
      - pkg: jool-packages
      - file: jool-config
      - file: jool-script
      - file: jool-unit
