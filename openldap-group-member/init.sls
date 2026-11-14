#
# memberOf for the team OpenLDAP on docker04 (dc=ffmuc,dc=net): a root timer mirrors the groups' memberUid into
# "member" (class dnMemberGroup), the memberof overlay then keeps memberOf on the users up to date. memberUid stays
# the source for every client. Needs the schema and the ACL/overlay change of infra ops/ffmuc-ldap-memberof.sh
# (phase apply) first, otherwise the unit fails (harmless, nothing is written).
# Rollback: systemctl disable --now ffmuc-ldap-group-member.timer, then the rollback phase of that script.
#
/usr/local/lib/ffmuc-ldap-group-member.sh:
  file.managed:
    - source: salt://openldap-group-member/files/ffmuc-ldap-group-member.sh
    - mode: "0644"

/usr/local/sbin/ffmuc-ldap-group-member:
  file.managed:
    - source: salt://openldap-group-member/files/ffmuc-ldap-group-member
    - mode: "0755"

/etc/systemd/system/ffmuc-ldap-group-member.service:
  file.managed:
    - source: salt://openldap-group-member/files/ffmuc-ldap-group-member.service

/etc/systemd/system/ffmuc-ldap-group-member.timer:
  file.managed:
    - source: salt://openldap-group-member/files/ffmuc-ldap-group-member.timer

systemd-reload-ffmuc-ldap-group-member:
  cmd.run:
    - name: systemctl --system daemon-reload
    - onchanges:
      - file: /etc/systemd/system/ffmuc-ldap-group-member.service
      - file: /etc/systemd/system/ffmuc-ldap-group-member.timer

ffmuc-ldap-group-member-timer:
  service.running:
    - name: ffmuc-ldap-group-member.timer
    - enable: True
    - require:
      - cmd: systemd-reload-ffmuc-ldap-group-member
      - file: /usr/local/lib/ffmuc-ldap-group-member.sh
      - file: /usr/local/sbin/ffmuc-ldap-group-member
