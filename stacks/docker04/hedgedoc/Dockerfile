# node2shell (CVE-2026-111497): the image ships Node 26.5.1, whose bundled
# Brotli decoder is vulnerable. Swap in the fixed Node of the same major line
# (native modules stay ABI compatible). Drop this file and go back to the
# upstream image once linuxserver ships Node >= 26.12.1.
FROM node:26.12.1-alpine3.24@sha256:40cd011b55415bc894e45b02fdd5a5dfde056921b7d23a64c74f80497af48797 AS node

FROM lscr.io/linuxserver/hedgedoc:1.12.0-ls208@sha256:0d9fe2aefb368577c44e7cc3a3c1bb6fcf79d5b05db46b9e46309a13e1831098
COPY --from=node /usr/local/bin/node /usr/bin/node
COPY --from=node /usr/lib/libatomic.so.1 /usr/lib/libatomic.so.1
