# node2shell (CVE-2026-111497): the image ships Node 18.19.0, whose bundled
# Brotli decoder is vulnerable and which gets no fixes any more. v2.0.1 is the
# latest release; only the unreleased `dev` tag has a fixed Node (22.23.4).
# Swap that Node in (the image is Alpine 3.19, musl like node:*-alpine). Drop
# this file and go back to the upstream image once a release ships a fixed Node.
FROM node:22.23.4-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202 AS node

FROM nttgin/bgpalerter:v2.0.1@sha256:c65a194221d2186d483008f154002b52c963465f9205d97fac15b2c94e690810
COPY --from=node /usr/local/bin/node /usr/local/bin/node
