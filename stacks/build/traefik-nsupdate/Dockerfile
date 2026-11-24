# Traefik plus nsupdate for the DNS-01 exec hook (update-dns.sh, Salt state certs). bind-tools is
# installed at build time, so the container needs neither a writable root nor apk at run time.
# Keep the tag and digest in step with the traefik image of the stacks.
FROM traefik:v3.8.0@sha256:cd3078e07dfe0c551b1df6fca2697c52f35da0a18c7bd81da4d3b1f012405098
RUN apk add --no-cache bind-tools
