# Roundcube with the club's colours and logos: Elastic compiled again with _variables.less, the skin's own hook
# for palette changes (skins/elastic/README.md); rebuilt on every Roundcube update, so the CSS always matches.
FROM roundcube/roundcubemail:1.7.6-apache-nonroot@sha256:6f3d54d5275bd843852bd2c7628988faa05d5c6ec33529a6fc9744ef20596c87 AS roundcube

FROM node:26.13.0-alpine@sha256:8996bb5821d62a8fd9bb27c1cb07462f3fdce6e47d640c6a881ead0b064ce216 AS skin
# renovate: datasource=npm depName=less
ARG LESS_VERSION=4.9.1
# renovate: datasource=npm depName=less-plugin-clean-css
ARG CLEAN_CSS_VERSION=1.6.0
WORKDIR /elastic
COPY --from=roundcube /usr/src/roundcubemail/skins/elastic/ ./
COPY _variables.less styles/
RUN npm install --global --no-fund --no-audit "less@${LESS_VERSION}" "less-plugin-clean-css@${CLEAN_CSS_VERSION}" \
 && lessc --clean-css="--s1 --advanced" styles/styles.less styles/styles.min.css \
 && lessc --clean-css="--s1 --advanced" styles/embed.less styles/embed.min.css

FROM roundcube
COPY --from=skin /elastic/styles/styles.min.css /elastic/styles/embed.min.css /usr/src/roundcubemail/skins/elastic/styles/
COPY logo.png logo-small.png favicon.png /usr/src/roundcubemail/skins/elastic/images/brand/
COPY legal_links/ /usr/src/roundcubemail/plugins/legal_links/
