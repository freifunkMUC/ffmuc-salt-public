#
# Meeting minutes (Usertreffen, last Wednesday of the month) from Etherpad into the DokuWiki on docker04: a weekly root
# timer takes the pads of meetings after the newest wiki page treffen:<YYMMDD> that are at least 7 days old, converts the
# pad HTML export and creates the page (never overwrites) plus its entry on treffen:start (only if unchanged since read).
# Written by docker exec as uid 1000 with DokuWiki's saveWikiText (history, minor edit), no password. Logs go to the journal:
# journalctl -u ffmuc-treffen-sync. Dry run: ffmuc-treffen-sync --dry-run
# Rollback: systemctl disable --now ffmuc-treffen-sync.timer (pages stay, they are in the page history).
#
/usr/local/sbin/ffmuc-treffen-sync:
  file.managed:
    - source: salt://dokuwiki-treffen-sync/files/ffmuc-treffen-sync.py
    - mode: "0755"

/etc/systemd/system/ffmuc-treffen-sync.service:
  file.managed:
    - source: salt://dokuwiki-treffen-sync/files/ffmuc-treffen-sync.service

/etc/systemd/system/ffmuc-treffen-sync.timer:
  file.managed:
    - source: salt://dokuwiki-treffen-sync/files/ffmuc-treffen-sync.timer

systemd-reload-ffmuc-treffen-sync:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-treffen-sync.service
      - file: /etc/systemd/system/ffmuc-treffen-sync.timer

ffmuc-treffen-sync-timer:
  service.running:
    - name: ffmuc-treffen-sync.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-treffen-sync
      - file: /usr/local/sbin/ffmuc-treffen-sync
