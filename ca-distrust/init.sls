# eMudhra intermediate CA keys compromised (20.10.2026), roots as removed in NSS 3.131.1 plus Comodo AAA; drop once ca-certificates ships without them
{%- set roots = ['emSign_ECC_Root_CA_-_G3', 'emSign_Root_CA_-_C1', 'emSign_ECC_Root_CA_-_C3', 'Comodo_AAA_Services_root'] %}
{%- for root in roots %}

ca-distrust-{{ root }}:
  file.replace:
    - name: /etc/ca-certificates.conf
    - pattern: '^mozilla/{{ root }}\.crt$'
    - repl: '!mozilla/{{ root }}.crt'
    - ignore_if_missing: True
{%- endfor %}

ca-distrust-update:
  cmd.run:
    - name: update-ca-certificates
    - onchanges:
{%- for root in roots %}
      - file: ca-distrust-{{ root }}
{%- endfor %}
