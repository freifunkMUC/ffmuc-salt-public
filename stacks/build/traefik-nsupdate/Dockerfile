# Traefik plus nsupdate for the DNS-01 exec hook (update-dns.sh, Salt state certs). bind-tools is
# installed at build time, so the container needs neither a writable root nor apk at run time.
# Keep the tag and digest in step with the traefik image of the stacks.
FROM traefik:v3.7.19@sha256:a6c0194dda77bcb804824580f36fa7edc56e315b1acfe933366c8b52844a78a4
RUN apk add --no-cache bind-tools
