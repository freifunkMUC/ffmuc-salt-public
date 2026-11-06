# Roundcube with the club's colours and logos: Elastic compiled again with _variables.less, the skin's own hook
# for palette changes (skins/elastic/README.md); rebuilt on every Roundcube update, so the CSS always matches.
FROM roundcube/roundcubemail:1.7.5-apache-nonroot@sha256:b0a0ed861d6786fad93ee33757470da605d4a39a4ff9081cdd4529e0196deaf9 AS roundcube

FROM node:24.22.2-alpine@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8 AS skin
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
