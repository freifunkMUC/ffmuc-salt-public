# node2shell (CVE-2026-111497): the image ships Node 22.12.0, whose bundled
# Brotli decoder is vulnerable. Swap in the fixed Node of the same major line.
# Drop this file and go back to the upstream image once it ships a fixed Node.
FROM node:22.23.4-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS node

FROM lovasoa/wbo:v1.22.1@sha256:2b3de45265a756d66f87c95a50e190cde93b091e24bf12a4c7c933ccfeddfe16
USER root
COPY --from=node /usr/local/bin/node /usr/local/bin/node
USER 1000:1000
