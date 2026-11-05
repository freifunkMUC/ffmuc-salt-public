<?php
// Merged into Roundcube's configuration by the image's entrypoint
// (/var/roundcube/config/*.php). The image writes its own config.inc.php on
// the first start of a container (log to stdout, zipdownload_selection,
// spell check with pspell); database, IMAP, SMTP, plugins and des_key come
// from the environment.

// Traefik connects from the Docker network "proxy"; only from there
// X-Forwarded-For and X-Forwarded-Proto are believed (logs and login rate
// limits see the client, the session cookie is marked secure).
$config['proxy_whitelist'] = ['172.18.0.0/16'];

// Club name and logos; the logo files and the colours are built into the image (roundcube/Dockerfile).
$config['product_name'] = 'Freifunk München Webmail';
$config['skin_logo'] = [
    'elastic:login' => '/images/brand/logo.png',
    'elastic:*' => '/images/brand/logo-small.png',
    '[favicon]' => '/images/brand/favicon.png',
];

// Imprint and privacy policy of the club in the login footer (plugin in roundcube/legal_links).
$config['plugins'][] = 'legal_links';
$config['legal_links'] = [
    'Impressum' => 'https://ffmuc.net/impressum/',
    'Datenschutz' => 'https://ffmuc.net/privacy/',
];
