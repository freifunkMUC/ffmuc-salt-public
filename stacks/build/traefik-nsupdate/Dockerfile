# Traefik plus nsupdate for the DNS-01 exec hook (update-dns.sh, Salt state certs). bind-tools is
# installed at build time, so the container needs neither a writable root nor apk at run time.
# Keep the tag and digest in step with the traefik image of the stacks.
FROM traefik:v3.7.20@sha256:8301d6f60957a422f98918aacf2b01482abde3e74ead3719aabdb7c64045fe28
RUN apk add --no-cache bind-tools
