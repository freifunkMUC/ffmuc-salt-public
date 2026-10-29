# node2shell (CVE-2026-111497): the image ships Node 18.19.0, whose bundled
# Brotli decoder is vulnerable and which gets no fixes any more. v2.0.1 is the
# latest release; only the unreleased `dev` tag has a fixed Node (22.23.4).
# Swap that Node in (the image is Alpine 3.19, musl like node:*-alpine). Drop
# this file and go back to the upstream image once a release ships a fixed Node.
FROM node:22.23.4-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS node

FROM nttgin/bgpalerter:v2.0.1@sha256:c65a194221d2186d483008f154002b52c963465f9205d97fac15b2c94e690810
COPY --from=node /usr/local/bin/node /usr/local/bin/node
