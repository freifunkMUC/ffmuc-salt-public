# node2shell (CVE-2026-111497): the image ships a vulnerable Node 24. Swap in
# the fixed Node of the same major line (native modules stay ABI compatible).
# Drop this file and go back to the upstream image once Mastodon ships
# Node >= 24.22.1.
FROM node:24.22.1-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea AS node

FROM ghcr.io/mastodon/mastodon-streaming:v4.7.3@sha256:770f2e1f734fd0ed69628292638211f909eb87769f73db026c36f484ad3c6bd6
COPY --from=node /usr/local/bin/node /usr/local/bin/node
