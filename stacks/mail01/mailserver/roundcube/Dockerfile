# Roundcube with the club's colours and logos: Elastic compiled again with _variables.less, the skin's own hook
# for palette changes (skins/elastic/README.md); rebuilt on every Roundcube update, so the CSS always matches.
FROM roundcube/roundcubemail:1.7.5-apache-nonroot@sha256:b0a0ed861d6786fad93ee33757470da605d4a39a4ff9081cdd4529e0196deaf9 AS roundcube

FROM node:24.22.2-alpine@sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85 AS skin
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
