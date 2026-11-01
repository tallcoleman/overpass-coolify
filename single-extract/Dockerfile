# The upstream image plus this deployment's scripts. b1tw153.yml passes
# OVERPASS_IMAGE as a build arg, so one variable picks the base for every service.
ARG OVERPASS_IMAGE=b1tw153/overpass-api:0.7.62.11-r21
FROM ${OVERPASS_IMAGE}
COPY scripts/ /scripts/
