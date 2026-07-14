# syntax=docker/dockerfile:1

ARG TELEMT_REPOSITORY=telemt/telemt
ARG TELEMT_VERSION=3.4.23
ARG ALLOW_TELEMT_LATEST=0

FROM debian:12-slim AS fetch
ARG TARGETARCH
ARG TELEMT_REPOSITORY
ARG TELEMT_VERSION
ARG ALLOW_TELEMT_LATEST

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      tar \
      binutils; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ASSET="telemt-x86_64-linux-musl.tar.gz" ;; \
      arm64) ASSET="telemt-aarch64-linux-musl.tar.gz" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    VERSION="${TELEMT_VERSION#refs/tags/}"; \
    if [ "${VERSION}" = "latest" ] && [ "${ALLOW_TELEMT_LATEST}" != "1" ]; then \
      echo "TELEMT_VERSION=latest is disabled for reproducible builds; use an exact release tag." >&2; \
      exit 1; \
    fi; \
    if [ -z "${VERSION}" ] || [ "${VERSION}" = "latest" ]; then \
      BASE_URL="https://github.com/${TELEMT_REPOSITORY}/releases/latest/download"; \
    else \
      BASE_URL="https://github.com/${TELEMT_REPOSITORY}/releases/download/${VERSION}"; \
    fi; \
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 10 --max-time 120 \
      -o "/tmp/${ASSET}" "${BASE_URL}/${ASSET}"; \
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 10 --max-time 120 \
      -o "/tmp/${ASSET}.sha256" "${BASE_URL}/${ASSET}.sha256"; \
    cd /tmp; \
    sha256sum -c "${ASSET}.sha256"; \
    tar -xzf "${ASSET}" -C /tmp; \
    test -f /tmp/telemt; \
    install -m 0755 /tmp/telemt /telemt; \
    strip --strip-unneeded /telemt || true; \
    /telemt --version || true

FROM debian:12-slim AS debug
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iproute2 \
      busybox \
      tzdata; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=fetch /telemt /app/telemt
RUN set -eux; \
    mkdir -p /etc/telemt; \
    chown -R 65532:65532 /etc/telemt /app
USER 65532:65532
EXPOSE 443 9090 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/app/telemt", "healthcheck", "/etc/telemt/telemt.toml", "--mode", "liveness"]
ENTRYPOINT ["/app/telemt"]
CMD ["/etc/telemt/telemt.toml"]

FROM gcr.io/distroless/static-debian12:nonroot AS prod
WORKDIR /etc/telemt
COPY --from=fetch /telemt /app/telemt
EXPOSE 443 9090 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/app/telemt", "healthcheck", "/etc/telemt/telemt.toml", "--mode", "liveness"]
ENTRYPOINT ["/app/telemt"]
CMD ["/etc/telemt/telemt.toml"]
