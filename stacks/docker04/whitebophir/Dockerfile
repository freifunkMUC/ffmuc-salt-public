# node2shell (CVE-2026-111497): the image ships Node 24.22.0, whose bundled
# Brotli decoder is vulnerable. Swap in the fixed Node of the same major line.
# Drop this file and go back to the upstream image once it ships a fixed Node.
FROM node:24.22.1-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53 AS node

FROM lovasoa/wbo:v2.18.25@sha256:371dcf468d7fa033ad6567230cdf25972efa639590cdf1ee026811cfc4329d08
USER root
COPY --from=node /usr/local/bin/node /usr/local/bin/node
USER 1000:1000
