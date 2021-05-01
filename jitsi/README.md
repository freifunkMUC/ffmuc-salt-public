# Jitsi Konfiguration für meet.ffmuc.net

In diesem Ordner haben wir früher unsere salt formulas für jitsi abgelegt.

Da wir von einigen Fällen mitbekommen haben, in denen unsere ehrenamtliche Arbeit genutzt wurde um z.B. ein Business überhaupt erst aufzubauen,
haben wir uns schweren Herzens dazu entschieden unsere Konfigurationen nur noch auf Anfrage herauszugeben.

Wichtig: Wir unterstützen weiterhin gerne bei der Einrichtung eurer Installation.
Wendet euch dazu gerne an die Community in unserem Chat: https://chat.ffmuc.net/freifunk/channels/services-meet

Für nicht-komerzielle oder bildungstechnische Zwecke geben wir den Zugang auch gerne frei.
Um direkten Zugriff auf unsere aktuellen salt formulas zu bekommen wendet euch an meet{ät}ffmuc.net.

Und wie immer: Man kann mit uns reden!
Solltest du Zugriff auf unser Repository haben wollen schildere uns kurz deinen Zweck und wir können einen Weg finden dir den Zugang zu ermöglichen.


docker exec -ti salt_salt-master_1 salt 'jvb*.meet.ffmuc.net' cmd.run 'bash -c "apt show jitsi-videobridge2 2>/dev/null | grep 2.1-416 && /usr/share/jitsi-videobridge/graceful_shutdown.sh >/tmp/graceful_update.log && salt-call state.apply jitsi.videobridge >> /tmp/graceful_update.log"' bg=true