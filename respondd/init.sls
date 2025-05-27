#
# respondd
# Source for template: https://github.com/ffggrz/ext-respondd.git
#

/etc/systemd/system/respondd@.service:
  file.managed:
    - source: salt://respondd/respondd-tmpl/respondd@.service

python3-netifaces:
   pkg.installed

{% set sites = salt['pillar.get']('netbox:config_context:sites') %}
{% for prefix, domains in sites.items() %}
{% for site in domains %}

{% if not salt['file.directory_exists']('/opt/respondd-' ~ site ) %}
/opt/respondd-{{ site }}:
  file.recurse:
    - source: salt://respondd/respondd-tmpl
    # try template: jinja option and get rid of below overridings
    - exclude_pat:
      - ".git/*"
    - watch_in:
        - service: respondd@{{ site }}
{% endif %}

/opt/respondd-{{ site }}/alias.json:
  file.managed:
    - source: salt://respondd/alias.json
    - template: jinja
    - defaults:
        site: {{ site }}
        prefix: {{ prefix }}
    - watch_in:
        - service: respondd@{{ site }}

/opt/respondd-{{ site }}/config.json:
  file.managed:
    - source: salt://respondd/config.json
    - template: jinja
    - defaults:
        site: {{ site }}
    - watch_in:
        - service: respondd@{{ site }}

/opt/respondd-{{ site }}/lib/respondd_client.py:
  file.managed:
    - source: salt://respondd/respondd-tmpl/lib/respondd_client.py
    - template: jinja
    - defaults:
        site: {{ site }}
    - watch_in:
        - service: respondd@{{ site }}


/opt/respondd-{{ site }}/ext-respondd.py:
  file.managed:
    - mode: "0755"
    # only to harm the salt gods to not complain with
    # "Neither 'source' nor 'contents' nor 'contents_pillar' nor 'contents_grains' was defined"
    - source: salt://respondd/respondd-tmpl/ext-respondd.py

respondd@{{ site }}:
  service.running:
    - enable: True
    - require:
      - file: /opt/respondd-{{ site }}/alias.json
      - file: /opt/respondd-{{ site }}/config.json
      - file: /etc/systemd/system/respondd@.service
{% endfor %}
{% endfor %}
