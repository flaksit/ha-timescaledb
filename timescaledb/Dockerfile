ARG BUILD_FROM
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

# Create data directory for persistent storage
RUN mkdir -p /data

# Copy rootfs (s6 service definitions, scripts)
COPY rootfs /

ENTRYPOINT ["/init"]
