# syntax=docker/dockerfile:1.7
#
# nginx-ui + dynamic modules:
#   - nginx-module-vts (with custom HTML dashboard baked in)
#   - ngx_devel_kit + lua-nginx-module (required by the CrowdSec lua bouncer)
# Plus:
#   - cs-nginx-bouncer (CrowdSec lua bouncer) installed at canonical paths
#   - reload API (POST /reload with X-API-Key)
#   - supercronic reading $CRONTAB_FILE
#
# Strategy: discover the exact nginx version shipped by uozi/nginx-ui, fetch
# the matching nginx source, compile all dynamic modules against it with
# --with-compat, then copy the .so files + bouncer assets into the final
# image. Runtime LuaJIT + lua-resty-* deps are installed in the final stage.

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
    if ! echo "$NGX_V" | grep -q -- '--with-compat'; then \
        echo "WARNING: upstream nginx is NOT compiled with --with-compat;" >&2; \
        echo "         dynamic modules may fail to load at runtime." >&2; \
    fi; \
    echo "Detected nginx version: $(cat /tmp/nginx_version)"; \
    echo "Detected modules path:  $(cat /tmp/modules_path)"

############################################################
# Stage 2: compile dynamic modules (VTS + NDK + lua-nginx-module)
############################################################
FROM debian:bookworm-slim AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates build-essential git curl make \
        libpcre2-dev libssl-dev zlib1g-dev \
        libluajit-5.1-dev luajit \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY --from=discover /tmp/nginx_version /tmp/nginx_version

RUN set -eux; \
    NGINX_VERSION="$(cat /tmp/nginx_version)"; \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz; \
    tar xzf nginx.tar.gz; \
    mv "nginx-${NGINX_VERSION}" nginx-src; \
    rm nginx.tar.gz

# Resolve module versions at build time. Empty ARG => fetch the latest release
# tag from GitHub. Pass a specific version as a --build-arg to override.
ARG NDK_VERSION=
ARG LUA_NGINX_VERSION=
ARG VTS_VERSION=
ARG CS_NGINX_BOUNCER_VERSION=

# Resolves "latest" tag for a repo (owner/repo), prints it on stdout. Aborts
# the build on failure rather than silently falling back, so we never produce
# an image with mystery versions.
RUN set -eux; \
    cat > /usr/local/bin/gh-latest-tag <<'SH'
#!/bin/sh
set -eu
repo="$1"
override="${2:-}"
if [ -n "$override" ]; then echo "$override"; exit 0; fi
url="https://api.github.com/repos/${repo}/releases/latest"
tag="$(curl -fsSL "$url" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]\+\)"$/\1/')"
if [ -z "$tag" ]; then
    echo "ERROR: could not resolve latest tag for $repo from $url" >&2
    exit 1
fi
echo "$tag"
SH
RUN chmod +x /usr/local/bin/gh-latest-tag

RUN set -eux; \
    NDK_VERSION="$(gh-latest-tag vision5/ngx_devel_kit            "${NDK_VERSION}")"; \
    LUA_NGINX_VERSION="$(gh-latest-tag openresty/lua-nginx-module "${LUA_NGINX_VERSION}")"; \
    VTS_VERSION="$(gh-latest-tag vozlt/nginx-module-vts           "${VTS_VERSION}")"; \
    echo "Using: ndk=$NDK_VERSION lua=$LUA_NGINX_VERSION vts=$VTS_VERSION"; \
    git clone --depth=1 --branch "$VTS_VERSION"        https://github.com/vozlt/nginx-module-vts.git; \
    git clone --depth=1 --branch "$NDK_VERSION"        https://github.com/vision5/ngx_devel_kit.git; \
    git clone --depth=1 --branch "$LUA_NGINX_VERSION"  https://github.com/openresty/lua-nginx-module.git

# Bake custom HTML dashboard into the VTS module
COPY status.html /tmp/status.html
RUN set -eux; \
    cd nginx-module-vts/util; \
    chmod +x tplToDefine.sh; \
    ./tplToDefine.sh /tmp/status.html \
        > ../src/ngx_http_vhost_traffic_status_module_html.h

# Configure + build the three dynamic modules. lua-nginx-module needs
# LUAJIT_LIB and LUAJIT_INC pointing at the LuaJIT install.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  lj_lib=/usr/lib/x86_64-linux-gnu ;; \
        aarch64) lj_lib=/usr/lib/aarch64-linux-gnu ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    export LUAJIT_LIB="$lj_lib"; \
    export LUAJIT_INC=/usr/include/luajit-2.1; \
    cd nginx-src; \
    ./configure --with-compat \
        --with-ld-opt="-Wl,-rpath,$lj_lib" \
        --add-dynamic-module=/build/nginx-module-vts \
        --add-dynamic-module=/build/ngx_devel_kit \
        --add-dynamic-module=/build/lua-nginx-module; \
    make modules -j"$(nproc)"; \
    ls -la objs/

# Build the cs-nginx-bouncer release tarball. `make release` clones the
# matching lua-cs-bouncer at the version pinned in the bouncer's Makefile and
# produces a tarball with the canonical install layout. Version resolved
# dynamically (latest release tag) unless CS_NGINX_BOUNCER_VERSION is set.
RUN set -eux; \
    CS_NGINX_BOUNCER_VERSION="$(gh-latest-tag crowdsecurity/cs-nginx-bouncer "${CS_NGINX_BOUNCER_VERSION}")"; \
    echo "Using cs-nginx-bouncer=$CS_NGINX_BOUNCER_VERSION"; \
    git clone --depth=1 --branch "$CS_NGINX_BOUNCER_VERSION" \
        https://github.com/crowdsecurity/cs-nginx-bouncer.git /build/cs-nginx-bouncer; \
    cd /build/cs-nginx-bouncer; \
    make release; \
    mkdir -p /build/bouncer-extracted; \
    tar xzf crowdsec-nginx-bouncer.tgz -C /build/bouncer-extracted --strip-components=1

# Assert the release tarball has the structure we expect. If upstream
# restructures it, the build fails LOUDLY here rather than silently producing
# a broken image. Anything missing is listed so the fix is obvious.
RUN set -eux; \
    echo "--- cs-nginx-bouncer release contents ---"; \
    find /build/bouncer-extracted -maxdepth 3 -printf '%P\n' | sort; \
    echo "-----------------------------------------"; \
    fail=0; \
    for path in \
        lua-mod \
        templates \
        templates/ban.html \
        templates/captcha.html \
        nginx/crowdsec_nginx.conf \
        crowdsec-nginx-bouncer.conf \
    ; do \
        if [ ! -e "/build/bouncer-extracted/$path" ]; then \
            echo "ASSERT FAIL: /build/bouncer-extracted/$path is missing" >&2; \
            fail=1; \
        fi; \
    done; \
    if [ "$fail" -ne 0 ]; then \
        echo "" >&2; \
        echo "cs-nginx-bouncer release layout changed. Update the COPY/install" >&2; \
        echo "logic in the Dockerfile to match the new structure." >&2; \
        exit 1; \
    fi

############################################################
# Stage 3: final image on top of nginx-ui
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG}

# Runtime deps: reload API, scripts, cron, LuaJIT runtime, lua deps for the
# CrowdSec bouncer. (Debian-based path; Alpine fallback kept for safety.)
RUN set -eux; \
    if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache socat curl sqlite tzdata coreutils findutils \
            luajit lua5.1 lua5.1-cjson lua5.1-resty-http gettext; \
    else \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            socat curl sqlite3 tzdata ca-certificates findutils \
            luajit libluajit-5.1-2 lua5.1 lua-cjson \
            luarocks gettext-base; \
        # lua-resty-http is not in Debian; install via luarocks against Lua 5.1
        # (LuaJIT is bytecode-compatible with Lua 5.1).
        luarocks-5.1 install lua-resty-http; \
        luarocks-5.1 install lua-resty-string; \
        apt-get purge -y --auto-remove luarocks; \
        rm -rf /var/lib/apt/lists/* /root/.cache; \
    fi

# Supercronic — minimal cron daemon driven by a crontab file.
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

# Place all three dynamic modules and enable them.
# NDK MUST be loaded before lua-nginx-module.
COPY --from=discover /tmp/modules_path /tmp/modules_path
COPY --from=builder /build/nginx-src/objs/ngx_http_vhost_traffic_status_module.so /tmp/mods/
COPY --from=builder /build/nginx-src/objs/ndk_http_module.so                       /tmp/mods/
COPY --from=builder /build/nginx-src/objs/ngx_http_lua_module.so                   /tmp/mods/

RUN set -eux; \
    MODULES_PATH="$(cat /tmp/modules_path)"; \
    mkdir -p "$MODULES_PATH" /etc/nginx/modules-available /etc/nginx/modules-enabled; \
    for so in ngx_http_vhost_traffic_status_module.so ndk_http_module.so ngx_http_lua_module.so; do \
        mv "/tmp/mods/$so" "$MODULES_PATH/$so"; \
        chmod 644 "$MODULES_PATH/$so"; \
    done; \
    # NDK first (10), lua second (15), VTS later (90) — load order matters for ndk/lua.
    printf 'load_module %s/ndk_http_module.so;\n'                          "$MODULES_PATH" > /etc/nginx/modules-available/10-mod-ndk.conf; \
    printf 'load_module %s/ngx_http_lua_module.so;\n'                      "$MODULES_PATH" > /etc/nginx/modules-available/15-mod-lua.conf; \
    printf 'load_module %s/ngx_http_vhost_traffic_status_module.so;\n'     "$MODULES_PATH" > /etc/nginx/modules-available/90-mod-vts.conf; \
    for f in 10-mod-ndk 15-mod-lua 90-mod-vts; do \
        ln -sf "/etc/nginx/modules-available/$f.conf" "/etc/nginx/modules-enabled/$f.conf"; \
    done; \
    rm -rf /tmp/mods /tmp/modules_path

# Install CrowdSec nginx bouncer assets into their canonical locations.
# Layout was already asserted in the builder stage, so we install
# unconditionally here — any failure means our COPY didn't pull what we
# expected, which is itself a bug worth surfacing.
COPY --from=builder /build/bouncer-extracted /tmp/bouncer
RUN set -eux; \
    mkdir -p /usr/local/lua/crowdsec /var/lib/crowdsec/lua/templates \
             /etc/crowdsec/bouncers /etc/nginx/conf.d; \
    cp -r /tmp/bouncer/lua-mod/.    /usr/local/lua/crowdsec/; \
    cp -r /tmp/bouncer/templates/.  /var/lib/crowdsec/lua/templates/; \
    cp /tmp/bouncer/nginx/crowdsec_nginx.conf \
       /etc/nginx/conf.d/crowdsec_nginx.conf; \
    cp /tmp/bouncer/crowdsec-nginx-bouncer.conf \
       /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf; \
    rm -rf /tmp/bouncer

# Scripts: reload API, maintenance, security.txt renewal, entrypoint
COPY reload-api.sh             /usr/local/bin/reload-api.sh
COPY maintain-nginx-ui-db.sh   /usr/local/bin/maintain-nginx-ui-db.sh
COPY security-txt-renew.sh     /usr/local/bin/security-txt-renew.sh
COPY nginx-body-cleanup.sh     /usr/local/bin/nginx-body-cleanup.sh
COPY render-bouncer-conf.sh    /usr/local/bin/render-bouncer-conf.sh
COPY custom-entrypoint.sh      /usr/local/bin/custom-entrypoint.sh
COPY status.html               /etc/nginx/vts-status.html
COPY default.crontab           /etc/cron.d/default.crontab

RUN chmod +x \
        /usr/local/bin/reload-api.sh \
        /usr/local/bin/maintain-nginx-ui-db.sh \
        /usr/local/bin/security-txt-renew.sh \
        /usr/local/bin/nginx-body-cleanup.sh \
        /usr/local/bin/render-bouncer-conf.sh \
        /usr/local/bin/custom-entrypoint.sh

# Defaults. Override at runtime as needed.
#   CROWDSEC_*       — fed into /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local
#                      by render-bouncer-conf.sh on each container start.
#   CRONTAB_FILE     — empty string disables cron.
ENV RELOAD_API_PORT=9010 \
    RELOAD_API_LISTEN=0.0.0.0 \
    NGINX_UI_DB_PATH=/etc/nginx-ui/database.db \
    SECURITY_TXT_PATH=/var/www/well-known/security.txt \
    SECURITY_TXT_RENEW_THRESHOLD_DAYS=30 \
    CRONTAB_FILE=/etc/cron.d/default.crontab \
    CROWDSEC_BOUNCER_ENABLED=false \
    CROWDSEC_LAPI_URL= \
    CROWDSEC_BOUNCER_API_KEY= \
    CROWDSEC_APPSEC_URL= \
    CROWDSEC_MODE=stream \
    CROWDSEC_BAN_TEMPLATE_PATH=/var/lib/crowdsec/lua/templates/ban.html \
    CROWDSEC_CAPTCHA_TEMPLATE_PATH=/var/lib/crowdsec/lua/templates/captcha.html

# Build-time smoke check: verify all three .so files are present at the
# discovered modules path, and that `nginx -t` succeeds with the bouncer
# disabled (the bouncer's init_by_lua_block needs a running LAPI, so it
# can't be exercised here). Fails the build if either check trips.
RUN set -eux; \
    MODULES_PATH="$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | sed 's/^--modules-path=//' || echo /usr/lib/nginx/modules)"; \
    for so in ngx_http_vhost_traffic_status_module.so ndk_http_module.so ngx_http_lua_module.so; do \
        if [ ! -f "$MODULES_PATH/$so" ]; then \
            echo "SMOKE FAIL: $so not present at $MODULES_PATH" >&2; \
            exit 1; \
        fi; \
    done; \
    # Move the bouncer snippet aside, run nginx -t, restore it.
    snippet=/etc/nginx/conf.d/crowdsec_nginx.conf; \
    if [ -f "$snippet" ]; then mv "$snippet" "${snippet}.smoke-backup"; fi; \
    nginx -t; \
    if [ -f "${snippet}.smoke-backup" ]; then mv "${snippet}.smoke-backup" "$snippet"; fi; \
    echo "smoke check OK"

EXPOSE 9010

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
