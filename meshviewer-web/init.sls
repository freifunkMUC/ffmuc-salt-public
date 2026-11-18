# yanic's JSON for the meshviewers on gw04 (#221): vhost and the links into /srv/yanic.
# The certificate stays with certbot (nginx authenticator); keep this list in sync with yanic/yanic.conf.tmpl.
{%- set fqdn = grains['id'] | replace('.in.ffmuc.net', '.ext.ffmuc.net') %}
{%- set files = ['meshviewer.json', 'meshviewer-augsburg.json', 'meshviewer-dlg.json', 'meshviewer-ffdon.json',
                 'meshviewer-ffwert.json', 'meshviewer-freising.json', 'meshviewer-ulm.json',
                 'nodes.json', 'nodes.geojson', 'nodelist.json'] %}

include:
  - nginx.gateway

/etc/nginx/sites-available/{{ fqdn }}:
  file.managed:
    - source: salt://meshviewer-web/files/vhost.conf.jinja
    - template: jinja
    - context:
        fqdn: {{ fqdn }}
        in_name: {{ grains['id'] }}
    - require:
      - pkg: nginx-pkg
    - onchanges_in:
      - cmd: nginx-gateway-configtest

/etc/nginx/sites-enabled/{{ fqdn }}:
  file.symlink:
    - target: /etc/nginx/sites-available/{{ fqdn }}
    - force: True
    - onchanges_in:
      - cmd: nginx-gateway-configtest

/srv/www/{{ fqdn }}/ffdon:
  file.directory:
    - makedirs: True

{%- for f in files %}
/srv/www/{{ fqdn }}/{{ f }}:
  file.symlink:
    - target: ../../yanic/{{ f }}
{%- endfor %}

/srv/www/{{ fqdn }}/ffdon/meshviewer.json:
  file.symlink:
    - target: ../../../yanic/meshviewer-ffdon.json
