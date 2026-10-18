### github-downloader rules
/usr/local/bin/firmware-downloader:
  file.managed:
    - source: salt://github-downloader/firmware-downloader
    - mode: "0755"
/usr/local/bin/ffmeet-downloader:
  file.managed:
    - source: salt://github-downloader/ffmeet-downloader
    - mode: "0755"
/usr/local/bin/firmware-legacy-merger:
  file.managed:
    - source: salt://github-downloader/firmware-legacy-merger
    - mode: "0755"
/usr/local/bin/xrx500-downloader:
  file.managed:
    - source: salt://github-downloader/xrx500-downloader
    - mode: "0755"

# xrx500-downloader unpacks GitHub Actions artifacts, which are zip files.
github-downloader-dependencies:
  pkg.installed:
    - pkgs:
      - unzip

{# GitHub only serves workflow artifacts to authenticated clients, even for public repositories.
   xrx500-downloader reads its token from this file. #}
{% if salt['pillar.get']('netbox:config_context:github_downloader:token') %}
/etc/github-downloader/token:
  file.managed:
    - contents_pillar: netbox:config_context:github_downloader:token
    - user: root
    - group: root
    - mode: "0600"
    - makedirs: True
    - dir_mode: "0700"
    - show_changes: False
{% endif %}
