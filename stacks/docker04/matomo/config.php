<?php
// Mounted as config/config.php: GeoIP database outside the code volume, so the update task can write it.
return [
    'path.geoip2' => '/var/lib/matomo/geoip/',
];
