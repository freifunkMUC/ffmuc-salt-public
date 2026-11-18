# Traefik plus nsupdate for the DNS-01 exec hook (update-dns.sh, Salt state certs). bind-tools is
# installed at build time, so the container needs neither a writable root nor apk at run time.
# Keep the tag and digest in step with the traefik image of the stacks.
FROM traefik:v3.7.19@sha256:aa942a00bce033c909bf1f7e861d93761be4b31a035f10d2410d33e38a8f41cf
RUN apk add --no-cache bind-tools
