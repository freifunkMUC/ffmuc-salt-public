{%- if 'backup' in salt['pillar.get']('netbox:tag_list', []) -%}
# runs daily to cleanup duplicity but slowly as rustic backups fill
backup-script:
  file.managed:
    - name: /usr/local/sbin/backup.sh
    - contents: |
        #!/usr/bin/env bash

        APPLICATION_KEY="{{ salt['config.get']('netbox:config_context:backblaze:application_key')  }}"
        KEYID="{{ salt['config.get']('netbox:config_context:backblaze:keyid') }}"
        export PASSPHRASE="{{ salt['config.get']('netbox:config_context:backup:password') }}"
        BUCKET="FFMUC-Backups"

        duplicity remove-older-than 14D --force b2://$KEYID:$APPLICATION_KEY@$BUCKET/{{ grains.id }}
        unset PASSPHRASE
    - mode: "0750"
    - template: jinja

ffmuc-backup-timer-disable:
  #service.dead:
  #  - name: ffmuc-backup.timer
  #  - enable: false
  service.running:
    - name: ffmuc-backup.timer
    - enable: true

{% endif %}{# if backup in tags #}
