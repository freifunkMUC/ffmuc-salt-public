# Traefik plus nsupdate for the DNS-01 exec hook (update-dns.sh, Salt state certs). bind-tools is
# installed at build time, so the container needs neither a writable root nor apk at run time.
# Keep the tag and digest in step with the traefik image of the stacks.
FROM traefik:v3.8.0@sha256:00c9734983e74ae35a1fc18eaee9e9da13f3dde95c4e45b3b8c3b60e0dbd2d17
RUN apk add --no-cache bind-tools
