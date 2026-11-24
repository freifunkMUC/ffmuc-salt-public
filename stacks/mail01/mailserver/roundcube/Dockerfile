# Roundcube with the club's colours and logos: Elastic compiled again with _variables.less, the skin's own hook
# for palette changes (skins/elastic/README.md); rebuilt on every Roundcube update, so the CSS always matches.
FROM roundcube/roundcubemail:1.7.7-apache-nonroot@sha256:c3cf002ddbc0a633bfab305ab4ea14f1d3f6d1ad7bbe37febb55dcd33edf1701 AS roundcube

FROM node:26.13.1-alpine@sha256:6bd9ab43c0ec0190ca7b2d193906cb8b7edf6e7f4afa43ddeccd6452710bffb5 AS skin
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
