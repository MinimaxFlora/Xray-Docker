# ---------------------------------------------------------------------------
#  Xray node image: XHTTP + VLESS Encryption (ML-KEM-768) + Vision + REALITY
#
#  The official image (ghcr.io/xtls/xray-core) is built on distroless and has
#  no shell, so the config generator cannot run inside it. We copy the very
#  same official binary + geo data into a tiny Alpine layer that does have
#  a POSIX shell, wget and ca-certificates.
#
#  Default is `latest`, i.e. the newest Xray-core release; the CI always passes
#  an explicit version (resolved from the upstream release) instead.
#  Override the base with e.g.  XRAY_IMAGE=ghcr.io/xtls/xray-core:26.10.29
# ---------------------------------------------------------------------------
ARG XRAY_IMAGE=ghcr.io/xtls/xray-core:latest

FROM ${XRAY_IMAGE} AS xray

FROM alpine:3

RUN apk add --no-cache ca-certificates tzdata \
    && update-ca-certificates

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=xray /usr/local/share/xray/geosite.dat /usr/local/share/xray/geosite.dat

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray

VOLUME ["/data"]
EXPOSE 443
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
