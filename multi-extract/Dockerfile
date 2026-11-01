# The upstream image plus the sidecar and init scripts, and supercronic for the
# sidecar's schedule. b1tw153-multiregion.yml passes OVERPASS_IMAGE as a build
# arg, so one variable picks the base for every service.
ARG OVERPASS_IMAGE=b1tw153/overpass-api:0.7.62.11-r21
FROM ${OVERPASS_IMAGE}

ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA1=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89
USER root
RUN curl -fsSL --retry 5 -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic
USER overpass

COPY sidecar/ /scripts/
