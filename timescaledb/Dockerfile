ARG BUILD_FROM

# pgbackrest staging image — discarded after binary + .so extraction.
# WHY multi-stage: Direct `apk add pgbackrest` in the runtime stage pulls the
# Alpine `postgresql18` server (~180 MiB) as a transitive dep, which collides
# with the source-built PG18 in /usr/local/bin and creates /etc/postgresql as
# a symlink that breaks `COPY rootfs /` later. Multi-stage takes only the
# pgbackrest binary plus missing .so libs (libssh2, libbz2) into the runtime.
# WHAT ldd guard catches: Future Alpine bumps may add runtime .so dependencies
# not present in the postgres:18-alpine image. The RUN step below fails the
# build if any symbol is unresolved.
# VERSION note: pgbackrest 2.58.0 is pulled from alpine:edge community because
# alpine:3.23 stable only ships 2.57.0 at time of writing. There is no known
# 2.57-vs-2.58 functional difference relevant to this app — both are subject
# to an upstream pgbackrest bug in storageSftpPathCreate (path-create infinite
# recursion when SFTP returns NO_SUCH_FILE walking up to `/`; no upstream issue
# filed yet). The bug is avoided by configuring pgBackRest against Hetzner
# *sub-account* chroots at repo-path `/`, not against the main account with
# subpaths. See DOCS.md section "Backup (pgBackRest to Hetzner Storage Box)".
FROM alpine:3.23 AS pgbackrest-stage

RUN apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/community pgbackrest

# Copy pgbackrest binary plus only the .so files not already in the postgres:18-alpine
# runtime image into /export/ for selective COPY into the runtime stage.
# Known delta libs vs postgres:18-alpine: libssh2.so.1, libbz2.so.1 — but ldd parsing
# catches future additions automatically.
RUN set -eux; \
    mkdir -p /export/usr/bin; \
    cp /usr/bin/pgbackrest /export/usr/bin/pgbackrest; \
    LIBS=$(ldd /usr/bin/pgbackrest | awk '/=>/ {print $3}' | grep -E '^/(usr/)?lib/' || true); \
    for L in $LIBS; do \
      mkdir -p "/export$(dirname $L)"; \
      cp -aL "$L" "/export$L"; \
    done

FROM ${BUILD_FROM}

ARG S6_OVERLAY_VERSION
ARG BASHIO_VERSION
ARG TEMPIO_VERSION
ARG TARGETARCH

ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0

# Install build dependencies (Alpine base image has wget but not curl or xz)
RUN apk add --no-cache curl xz jq

# Install s6-overlay (MUST use -p flag to preserve permissions)
RUN set -eux; \
    case "${TARGETARCH}" in \
      "amd64") S6_ARCH="x86_64" ;; \
      "arm64") S6_ARCH="aarch64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -L -f -o /tmp/s6-overlay-noarch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -L -f -o /tmp/s6-overlay-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz; \
    rm -f /tmp/s6-overlay-*.tar.xz

# Install bashio
RUN set -eux; \
    mkdir -p /usr/src/bashio; \
    curl -L -f -s "https://github.com/hassio-addons/bashio/archive/v${BASHIO_VERSION}.tar.gz" \
      | tar -xzf - --strip 1 -C /usr/src/bashio; \
    mv /usr/src/bashio/lib /usr/lib/bashio; \
    ln -s /usr/lib/bashio/bashio /usr/bin/bashio; \
    rm -rf /usr/src/bashio

# Install tempio
RUN set -eux; \
    case "${TARGETARCH}" in \
      "amd64") TEMPIO_ARCH="amd64" ;; \
      "arm64") TEMPIO_ARCH="aarch64" ;; \
    esac; \
    curl -L -f -o /usr/bin/tempio \
      "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_${TEMPIO_ARCH}"; \
    chmod +x /usr/bin/tempio

# Install pgbackrest from staging image — see top-of-file comment block for rationale.
# Copies binary + delta .so libs (libssh2, libbz2) from /export/ into the runtime
# filesystem, then fails the build immediately if any symbol is unresolved.
COPY --from=pgbackrest-stage /export/ /

RUN set -eux; \
    UNRESOLVED=$(ldd /usr/bin/pgbackrest | grep 'not found' || true); \
    if [ -n "$UNRESOLVED" ]; then \
      echo "ERROR: pgbackrest has unresolved .so dependencies:"; \
      echo "$UNRESOLVED"; \
      exit 1; \
    fi; \
    /usr/bin/pgbackrest version | grep -E '^pgBackRest 2\.[0-9]+\.[0-9]+'

# Create data directory for persistent storage
RUN mkdir -p /data

# Copy rootfs (s6 service definitions, scripts)
COPY rootfs /

ENTRYPOINT ["/init"]
