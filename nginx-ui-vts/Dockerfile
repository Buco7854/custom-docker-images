# syntax=docker/dockerfile:1.7
#
# nginx-ui + nginx-module-vts (with custom HTML dashboard bundled) + reload API
#
# Strategy: discover the exact nginx version shipped by uozi/nginx-ui at build
# time, fetch the matching nginx source from nginx.org, then compile VTS as a
# dynamic module against it with --with-compat. The .so is copied into the
# final layer; the custom status.html is baked into the module via tplToDefine.sh.

ARG NGINX_UI_TAG=latest

############################################################
# Stage 1: discover nginx version + modules path
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS discover

RUN set -eux; \
    nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' > /tmp/nginx_version; \
    NGX_V="$(nginx -V 2>&1)"; \
    echo "$NGX_V" | grep -oE -- '--modules-path=[^ ]+' \
        | sed 's/^--modules-path=//' > /tmp/modules_path \
        || echo "/usr/lib/nginx/modules" > /tmp/modules_path; \
    test -s /tmp/modules_path || echo "/usr/lib/nginx/modules" > /tmp/modules_path; \
    echo "Detected nginx version: $(cat /tmp/nginx_version)"; \
    echo "Detected modules path: $(cat /tmp/modules_path)"

############################################################
# Stage 2: compile nginx-module-vts as a dynamic module
############################################################
FROM debian:bookworm-slim AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates build-essential git curl \
        libpcre2-dev libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY --from=discover /tmp/nginx_version /tmp/nginx_version

RUN set -eux; \
    NGINX_VERSION="$(cat /tmp/nginx_version)"; \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz; \
    tar xzf nginx.tar.gz; \
    mv "nginx-${NGINX_VERSION}" nginx-src; \
    rm nginx.tar.gz

RUN git clone --depth=1 https://github.com/vozlt/nginx-module-vts.git

# Inject custom HTML dashboard into the module before compile
COPY status.html /tmp/status.html
RUN set -eux; \
    cd nginx-module-vts/util; \
    chmod +x tplToDefine.sh; \
    ./tplToDefine.sh /tmp/status.html \
        > ../src/ngx_http_vhost_traffic_status_module_html.h

RUN set -eux; \
    cd nginx-src; \
    ./configure --with-compat --add-dynamic-module=/build/nginx-module-vts; \
    make modules -j"$(nproc)"; \
    ls -la objs/

############################################################
# Stage 3: final image on top of nginx-ui
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG}

# Install runtime deps for the reload API + maintenance scripts + cron.
# uozi/nginx-ui has historically been Debian-based; handle Alpine just in case.
RUN set -eux; \
    if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache socat curl sqlite tzdata coreutils findutils; \
    else \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            socat curl sqlite3 tzdata ca-certificates findutils; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Install supercronic — a minimal, container-friendly cron daemon that reads
# a crontab file. Pinned by SHA1 (the form supercronic publishes in releases).
ARG SUPERCRONIC_VERSION=v0.2.45
ARG SUPERCRONIC_SHA1_AMD64=e894b193bea75a5ee644e700c59e30eedc804cf7
ARG SUPERCRONIC_SHA1_ARM64=20ce6dace414a64f0632f4092d6d3745db6085ad
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  sc_arch=amd64; sc_sha="${SUPERCRONIC_SHA1_AMD64}";; \
        aarch64) sc_arch=arm64; sc_sha="${SUPERCRONIC_SHA1_ARM64}";; \
        *) echo "unsupported arch: $arch" >&2; exit 1;; \
    esac; \
    url="https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${sc_arch}"; \
    curl -fsSL "$url" -o /usr/local/bin/supercronic; \
    echo "${sc_sha}  /usr/local/bin/supercronic" | sha1sum -c -; \
    chmod +x /usr/local/bin/supercronic

# Drop the VTS module into the correct modules path and enable it
COPY --from=discover /tmp/modules_path /tmp/modules_path
COPY --from=builder /build/nginx-src/objs/ngx_http_vhost_traffic_status_module.so /tmp/vts.so

RUN set -eux; \
    MODULES_PATH="$(cat /tmp/modules_path)"; \
    mkdir -p "$MODULES_PATH" /etc/nginx/modules-available /etc/nginx/modules-enabled; \
    mv /tmp/vts.so "$MODULES_PATH/ngx_http_vhost_traffic_status_module.so"; \
    chmod 644 "$MODULES_PATH/ngx_http_vhost_traffic_status_module.so"; \
    printf 'load_module %s/ngx_http_vhost_traffic_status_module.so;\n' "$MODULES_PATH" \
        > /etc/nginx/modules-available/90-mod-vts.conf; \
    ln -sf /etc/nginx/modules-available/90-mod-vts.conf /etc/nginx/modules-enabled/90-mod-vts.conf; \
    rm -f /tmp/modules_path

# Scripts: reload API, maintenance, security.txt renewal, entrypoint
COPY reload-api.sh             /usr/local/bin/reload-api.sh
COPY maintain-nginx-ui-db.sh   /usr/local/bin/maintain-nginx-ui-db.sh
COPY security-txt-renew.sh     /usr/local/bin/security-txt-renew.sh
COPY nginx-body-cleanup.sh     /usr/local/bin/nginx-body-cleanup.sh
COPY custom-entrypoint.sh      /usr/local/bin/custom-entrypoint.sh
COPY status.html               /etc/nginx/vts-status.html
COPY default.crontab           /etc/cron.d/default.crontab

RUN chmod +x \
        /usr/local/bin/reload-api.sh \
        /usr/local/bin/maintain-nginx-ui-db.sh \
        /usr/local/bin/security-txt-renew.sh \
        /usr/local/bin/nginx-body-cleanup.sh \
        /usr/local/bin/custom-entrypoint.sh

# CRONTAB_FILE: path inside the container; mount your own to override.
# Set CRONTAB_FILE="" to disable cron entirely.
ENV RELOAD_API_PORT=9010 \
    RELOAD_API_LISTEN=0.0.0.0 \
    NGINX_UI_DB_PATH=/etc/nginx-ui/database.db \
    SECURITY_TXT_PATH=/var/www/well-known/security.txt \
    SECURITY_TXT_RENEW_THRESHOLD_DAYS=30 \
    CRONTAB_FILE=/etc/cron.d/default.crontab

EXPOSE 9010

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
