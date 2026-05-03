ARG BUILD_FROM

# pgbackrest staging image — uses Debian bookworm (glibc), NOT Alpine (musl).
# WHY Debian: Alpine's musl libc causes a segfault in pgBackRest's libssh2 SFTP
# code on aarch64 (confirmed: same pgBackRest 2.58.0 binary crashes on Alpine/musl,
# runs cleanly on Debian/glibc). The root cause is in musl's threading or memory
# model interacting with libssh2's SFTP write path. Switching the staging image to
# Debian and running the glibc binary on Alpine via `gcompat` is the fix.
# WHY gcompat: Alpine's `gcompat` package ships the glibc ABI compatibility layer
# (ld-linux-aarch64.so.1 + libgcompat.so.0), allowing glibc-compiled binaries to
# run on musl Alpine without a full glibc installation.
# WHY multi-stage copy: imports glibc pgbackrest + its .so deps (libssh2, libssl,
# libpq, etc.) into the runtime image. The ldd guard catches any unresolved symbols.
FROM debian:bookworm-slim AS pgbackrest-stage

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends curl gnupg2 ca-certificates && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends pgbackrest

# Export pgbackrest binary + all its glibc .so dependencies + the glibc dynamic
# linker (ld-linux-aarch64.so.1). gcompat on the runtime provides the linker shim,
# but the actual glibc .so files must be present for the binary to link correctly.
RUN set -eux; \
    mkdir -p /export/usr/bin /export/lib; \
    cp /usr/bin/pgbackrest /export/usr/bin/pgbackrest; \
    LIBS=$(ldd /usr/bin/pgbackrest | awk '/=>/ {print $3}' | grep -E '^/(usr/)?lib/' || true); \
    for L in $LIBS; do \
      [ -f "$L" ] || continue; \
      mkdir -p "/export$(dirname $L)"; \
      cp -aL "$L" "/export$L"; \
    done; \
    cp -aL /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 /export/lib/ 2>/dev/null || \
    find /lib -name 'ld-linux-aarch64.so*' -exec cp -aL {} /export/lib/ \;

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

# gcompat: glibc ABI compatibility layer for Alpine — required to run the
# Debian-compiled (glibc) pgbackrest binary. Provides ld-linux-aarch64.so.1 shim.
RUN apk add --no-cache gcompat

# Install pgbackrest from Debian staging image — see top-of-file comment block.
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
