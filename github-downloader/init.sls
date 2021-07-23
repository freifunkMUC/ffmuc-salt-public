### github-downloader rules
/usr/local/bin/firmware-downloader:
  file.managed:
    - source: salt://github-downloader/firmware-downloader
    - mode: "0755"
/usr/local/bin/ffmeet-downloader:
  file.managed:
    - source: salt://github-downloader/ffmeet-downloader
    - mode: "0755"
