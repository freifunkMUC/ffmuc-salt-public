###
# Jitsi Meet Web Package
###
{%- from "jitsi/map.jinja" import jitsi with context %}

{% if jitsi.meet.enabled %}

include:
  - jitsi.base

# Upstream packages from download.jitsi.org. FFMUC branding is laid on top
# below (web-overlay, static-ffmuc, dynamic branding labels in config.js).
jitsi-meet-web-pkgs:
  pkg.installed:
    - pkgs:
      - jitsi-meet-web: {{ jitsi.meet.version }}
      - jitsi-meet-web-config: {{ jitsi.meet.version }}
    - hold: True
    - update_holds: True
    - require:
      - pkgrepo: jitsi-repo

# Files shipped by the package, so re-apply after every package change.
jitsi-meet-web-overlay:
  file.recurse:
    - name: /usr/share/jitsi-meet
    - source: salt://jitsi/meet/web-overlay
    - file_mode: '0644'
    - dir_mode: '0755'
    - require:
      - pkg: jitsi-meet-web-pkgs

# Link the FFMUC static files with ?v=<content hash>. nginx sends no
# Cache-Control, so browsers can keep old files for days. A new hash gives a
# new URL each time a file changes.
{%- set ver = {} %}
{%- for f in ["ffmuc.css", "placeholder.js", "reserved-rooms.js"] %}
{%-   do ver.update({f: salt["cp.hash_file"]("salt://jitsi/meet/static-ffmuc/" ~ f)["hsum"][:10]}) %}
{%- endfor %}
{% for src, dst in [("plugin.head.html", "plugin.head.html"), ("recommendedBrowsers.html", "static/recommendedBrowsers.html")] %}
/usr/share/jitsi-meet/{{ dst }}:
  file.managed:
    - source: salt://jitsi/meet/{{ src }}.jinja
    - template: jinja
    - mode: '0644'
    - context:
        ver: {{ ver | json }}
    - require:
      - file: jitsi-meet-web-overlay
      - file: /usr/share/jitsi-meet/static/ffmuc
{% endfor %}

{% for domain in ["meet.ffmuc.net","klassenkonferenz.de"] %}
/etc/jitsi/meet/{{ domain }}-config.js:
  file.managed:
    - source:
      - salt://jitsi/meet/{{ domain }}-config.js.jinja
      - salt://jitsi/meet/domain-config.js.jinja
    - template: jinja
    - defaults:
        domain: {{ domain }}
{% endfor %}

/usr/share/jitsi-meet/interface_config.js:
  file.managed:
    - source:
      - salt://jitsi/meet/interface_config.js

/usr/share/jitsi-meet/static/ffmuc:
  file.recurse:
    - source: salt://jitsi/meet/static-ffmuc
    - file_mode: '0644'
    - dir_mode: '0755'
    - clean: True
    - require:
      - pkg: jitsi-meet-web-pkgs

/etc/jitsi/meet/numbers.json:
  file.managed:
    - source: salt://jitsi/meet/numbers.json

{% endif %}
