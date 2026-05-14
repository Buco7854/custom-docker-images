# syntax=docker/dockerfile:1.7
#
# nginx-ui + dynamic modules:
#   - nginx-module-vts          (compiled from source — no Debian package)
#   - ngx_http_lua_module       (Debian's libnginx-mod-http-lua, with NDK
#                                bundled in by Debian's packaging)
# Plus:
#   - cs-nginx-bouncer (CrowdSec lua bouncer) installed at canonical paths
#   - reload API (POST /reload with X-API-Key)
#   - supercronic reading $CRONTAB_FILE
#
# Strategy:
#   * VTS has no Debian package, so we compile it from source against the
#     exact nginx version that uozi/nginx-ui ships, with --with-compat.
#   * lua-nginx-module IS packaged by Debian (`libnginx-mod-http-lua`); both
#     it and uozi's nginx are built with --with-compat, so the Debian-built
#     .so loads cleanly into uozi's nginx without us having to compile it.
#     Massive simplification — no luajit-dev, no NDK git clone, no version
#     resolution dance for that piece. Debian's security team patches CVEs;
#     daily rebuild picks them up.
#   * The bouncer is fetched as the upstream Debian .deb (signed via the
#     pinned CrowdSec GPG key).
#
# SUPPLY-CHAIN PINNING — the base image is pinned by SHA256 digest, not tag.
# Dependabot's docker ecosystem opens PRs to bump the digest; each bump goes
# through the same smoke + CVE scan + cosign signing pipeline before publish.
# The tag-after-image-name is informational only (for human readability);
# what's actually pulled is the digest. To override at build time:
#   docker build --build-arg NGINX_UI_REF=uozi/nginx-ui@sha256:...
ARG NGINX_UI_REF=uozi/nginx-ui:latest@sha256:18e009213e949373523861732bbef0af0d076c8d1b593b8b66bf873f70b4be5c

############################################################
# Stage 1: discover nginx version + modules path
############################################################
FROM ${NGINX_UI_REF} AS discover

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
# Match the runtime base (uozi/nginx-ui is built on debian trixie). Compiling
# against the same release means our dynamic modules link against the SAME
# luajit / pcre2 / ssl / zlib versions that will be present at runtime.
FROM debian:trixie-slim AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates build-essential git curl make \
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

# Resolve VTS version at build time. Empty ARG => fetch the latest release
# tag from GitHub. Pass a specific version as a --build-arg to override.
ARG VTS_VERSION=
ARG CS_NGINX_BOUNCER_VERSION=

# Resolves "latest" tag for a repo (owner/repo), prints it on stdout.
# Tries /releases/latest first (works for repos that publish formal
# releases), then falls back to /tags?per_page=1 — necessary for repos
# like openresty/lua-nginx-module that push tags but never click
# "publish release" in GitHub's UI (releases/latest -> 404).
#
# Uses $GH_TOKEN for authentication if set; without it the API rate limit
# is 60/hr per (shared) runner IP and easy to trip. With it: 5000/hr.
RUN set -eux; \
    cat > /usr/local/bin/gh-latest-tag <<'SH'
#!/bin/sh
set -eu
repo="$1"
override="${2:-}"
if [ -n "$override" ]; then echo "$override"; exit 0; fi

fetch() {
    # No -f: we want to get the body and decide ourselves, so a 404 on
    # /releases/latest cleanly falls through to /tags instead of aborting.
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -sSL -H "Authorization: Bearer ${GH_TOKEN}" "$1" || true
    else
        curl -sSL "$1" || true
    fi
}

resp="$(fetch "https://api.github.com/repos/${repo}/releases/latest")"
tag="$(printf '%s' "$resp" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]\+\)"$/\1/')"

if [ -z "$tag" ]; then
    resp="$(fetch "https://api.github.com/repos/${repo}/tags?per_page=1")"
    tag="$(printf '%s' "$resp" | grep -oE '"name":[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]\+\)"$/\1/')"
fi

if [ -z "$tag" ]; then
    echo "ERROR: could not resolve a tag for $repo (no releases and no tags?)" >&2
    exit 1
fi
echo "$tag"
SH
RUN chmod +x /usr/local/bin/gh-latest-tag

# The GitHub token is mounted as a build secret only for this single RUN.
# It's optional — without it, gh-latest-tag falls back to unauthenticated
# requests (and may hit the 60/hr rate limit on a shared runner IP).
RUN --mount=type=secret,id=github_token \
    set -eux; \
    if [ -s /run/secrets/github_token ]; then \
        export GH_TOKEN="$(cat /run/secrets/github_token)"; \
    fi; \
    VTS_VERSION="$(gh-latest-tag vozlt/nginx-module-vts "${VTS_VERSION}")"; \
    unset GH_TOKEN; \
    echo "Using: vts=$VTS_VERSION"; \
    git clone --depth=1 --branch "$VTS_VERSION" https://github.com/vozlt/nginx-module-vts.git

# Bake custom HTML dashboard into the VTS module
COPY status.html /tmp/status.html
RUN set -eux; \
    cd nginx-module-vts/util; \
    chmod +x tplToDefine.sh; \
    ./tplToDefine.sh /tmp/status.html \
        > ../src/ngx_http_vhost_traffic_status_module_html.h

# Configure + build VTS as a dynamic module. Just VTS — lua-nginx-module
# is pulled in below from Debian as a pre-built .so.
RUN set -eux; \
    cd nginx-src; \
    ./configure --with-compat \
        --add-dynamic-module=/build/nginx-module-vts; \
    make modules -j"$(nproc)"; \
    ls -la objs/

# Fetch the OFFICIAL CrowdSec nginx bouncer .deb from the upstream apt repo,
# then extract files without running its postinst (which would try to
# register with a non-existent local cscli). This pins us to the same files,
# at the same canonical Debian paths, that anyone running
# `apt install crowdsec-nginx-bouncer` on a Debian host would get:
#
#   /usr/lib/crowdsec/lua/                       lua modules
#   /var/lib/crowdsec/lua/templates/             ban / captcha HTML
#   /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf
#   /etc/nginx/conf.d/crowdsec_nginx.conf        the http-level snippet
#
# CS_NGINX_BOUNCER_VERSION empty -> install whatever apt offers as latest.
# Set it to a specific version (e.g. 1.1.6) to pin.
# CrowdSec packagecloud GPG fingerprint, full 40-hex. We fetch the key
# over HTTPS, compute its fingerprint locally with gpg, and refuse to
# proceed unless it matches exactly. This is strictly better than
# `curl install.crowdsec.net | bash`, which is what the upstream "install"
# instructions do — that pattern runs arbitrary remote shell code at build
# time with no integrity check beyond TLS.
ARG CROWDSEC_GPG_FINGERPRINT=6A89E3C2303A901A889971D3376ED5326E93CD0C
ARG CROWDSEC_DEBIAN_RELEASE=trixie

# When BOTH are set: pin to this exact .deb. The build aborts if either the
# version pulled from apt isn't `CS_NGINX_BOUNCER_VERSION` or its sha256
# doesn't match. This defends against a compromised CrowdSec signing key
# (which would otherwise sign a malicious .deb that passes apt's checks).
#
# When EITHER is empty: get whatever apt offers as latest, log the hash so
# you can capture it for next time. Apt's GPG chain still verifies, just no
# protection against key compromise.
#
# Update workflow:
#   1. CrowdSec releases a new version.
#   2. Bump CS_NGINX_BOUNCER_VERSION here, run the build.
#   3. Build logs the new sha256.
#   4. Verify the version is legit (release notes, community sanity check).
#   5. Paste the sha256 into CS_NGINX_BOUNCER_SHA256, re-build.
# Or set both ARGs via build-args / workflow inputs.
ARG CS_NGINX_BOUNCER_SHA256=

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg dirmngr; \
    # Fetch the key, verify fingerprint, install into keyring dir.
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey -o /tmp/crowdsec.key; \
    fpr="$(gpg --show-keys --with-fingerprint --with-colons /tmp/crowdsec.key \
            | awk -F: '/^fpr/ {print $10; exit}')"; \
    if [ "$fpr" != "${CROWDSEC_GPG_FINGERPRINT}" ]; then \
        echo "ERROR: CrowdSec GPG fingerprint mismatch." >&2; \
        echo "  expected: ${CROWDSEC_GPG_FINGERPRINT}" >&2; \
        echo "  got:      $fpr" >&2; \
        exit 1; \
    fi; \
    echo "CrowdSec GPG fingerprint verified: $fpr"; \
    mkdir -p /usr/share/keyrings; \
    gpg --dearmor < /tmp/crowdsec.key > /usr/share/keyrings/crowdsec.gpg; \
    rm /tmp/crowdsec.key; \
    echo "deb [signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ ${CROWDSEC_DEBIAN_RELEASE} main" \
        > /etc/apt/sources.list.d/crowdsec.list; \
    apt-get update; \
    mkdir -p /build/bouncer-deb /build/lua-deb; \
    cd /build/bouncer-deb; \
    if [ -n "${CS_NGINX_BOUNCER_VERSION}" ]; then \
        apt-get download "crowdsec-nginx-bouncer=${CS_NGINX_BOUNCER_VERSION}*"; \
    else \
        apt-get download crowdsec-nginx-bouncer; \
    fi; \
    # libnginx-mod-http-lua comes from Debian main (not packagecloud) and
    # also bundles whatever NDK pieces lua-nginx-module needs to run.
    cd /build/lua-deb; \
    apt-get download libnginx-mod-http-lua; \
    cd /build/bouncer-deb; \
    deb="$(ls crowdsec-nginx-bouncer_*.deb)"; \
    # Compute and ALWAYS log the .deb's sha256. If CS_NGINX_BOUNCER_SHA256
    # is set, also abort the build on mismatch. This is the final defense
    # against the scenario "CrowdSec's GPG signing key itself is compromised
    # and used to sign a malicious .deb under an existing version number".
    # Apt's GPG chain protects everything up to that point; the hash pin
    # protects against a compromised key.
    actual_sha="$(sha256sum "$deb" | awk '{print $1}')"; \
    echo "==============================================================="; \
    echo "  cs-nginx-bouncer .deb: $deb"; \
    echo "  sha256:               $actual_sha"; \
    echo "==============================================================="; \
    if [ -n "${CS_NGINX_BOUNCER_SHA256}" ]; then \
        if [ "$actual_sha" != "${CS_NGINX_BOUNCER_SHA256}" ]; then \
            echo "ERROR: sha256 mismatch for $deb" >&2; \
            echo "  expected: ${CS_NGINX_BOUNCER_SHA256}" >&2; \
            echo "  got:      $actual_sha" >&2; \
            echo "" >&2; \
            echo "Either CrowdSec released a new build of this version (review" >&2; \
            echo "their release notes and bump CS_NGINX_BOUNCER_SHA256), or" >&2; \
            echo "their signing key has been compromised (do NOT bump until you" >&2; \
            echo "have confirmation it's safe)." >&2; \
            exit 1; \
        fi; \
        echo "sha256 pin verified."; \
    else \
        echo "NOTE: CS_NGINX_BOUNCER_SHA256 not set — relying on apt's GPG"; \
        echo "      chain only. Set this build-arg to the sha256 printed"; \
        echo "      above to also defend against CrowdSec signing-key compromise."; \
    fi; \
    mkdir -p /build/bouncer-extracted /build/lua-extracted; \
    dpkg-deb -x "$deb" /build/bouncer-extracted; \
    dpkg-deb -x /build/lua-deb/libnginx-mod-http-lua_*.deb /build/lua-extracted

# Assert both .debs have the structure we expect. If upstream restructures
# either package, fail loudly here rather than silently producing a broken image.
RUN set -eux; \
    echo "--- crowdsec-nginx-bouncer .deb contents ---"; \
    find /build/bouncer-extracted -maxdepth 4 -printf '%P\n' | sort; \
    echo "--- libnginx-mod-http-lua .deb contents ---"; \
    find /build/lua-extracted -maxdepth 4 -printf '%P\n' | sort; \
    echo "--------------------------------------------"; \
    fail=0; \
    for path in \
        usr/lib/crowdsec/lua/crowdsec.lua \
        var/lib/crowdsec/lua/templates/ban.html \
        var/lib/crowdsec/lua/templates/captcha.html \
        etc/nginx/conf.d/crowdsec_nginx.conf \
        etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf \
    ; do \
        if [ ! -e "/build/bouncer-extracted/$path" ]; then \
            echo "ASSERT FAIL: /build/bouncer-extracted/$path is missing" >&2; \
            fail=1; \
        fi; \
    done; \
    # The Debian lua-module .deb must at minimum ship the lua .so. NDK may
    # be bundled in the same .deb or compiled into the lua module — we
    # accept either.
    if ! ls /build/lua-extracted/usr/lib/nginx/modules/ngx_http_lua_module.so >/dev/null 2>&1; then \
        echo "ASSERT FAIL: ngx_http_lua_module.so not present in libnginx-mod-http-lua" >&2; \
        fail=1; \
    fi; \
    if [ "$fail" -ne 0 ]; then \
        echo "" >&2; \
        echo "crowdsec-nginx-bouncer .deb layout changed. Update the COPY/install" >&2; \
        echo "logic in the Dockerfile to match the new structure." >&2; \
        exit 1; \
    fi

############################################################
# Stage 3: final image on top of nginx-ui
############################################################
# Re-declare the ARG so it's available in this stage too. Same digest pin
# as the discover stage above.
ARG NGINX_UI_REF
FROM ${NGINX_UI_REF}

# Assert Debian base. uozi/nginx-ui has been Debian (currently trixie) for a
# long time; if upstream ever switches to Alpine this build needs to be
# reworked anyway, so fail fast.
RUN set -eux; \
    if ! grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then \
        echo "ERROR: base image is not Debian-family:" >&2; \
        cat /etc/os-release >&2; \
        exit 1; \
    fi

# Runtime deps: reload API, scripts, cron, LuaJIT runtime, lua deps for the
# CrowdSec bouncer.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        socat curl sqlite3 tzdata ca-certificates findutils \
        luajit libluajit-5.1-2 lua5.1 lua-cjson \
        luarocks gettext-base; \
    # lua-resty-http isn't in Debian main; install via luarocks against Lua 5.1
    # (LuaJIT is bytecode-compatible with Lua 5.1).
    luarocks-5.1 install lua-resty-http; \
    luarocks-5.1 install lua-resty-string; \
    apt-get purge -y --auto-remove luarocks; \
    rm -rf /var/lib/apt/lists/* /root/.cache

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

# Place the dynamic modules and enable them.
#   * VTS: compiled in this image.
#   * lua-nginx-module (+ NDK if shipped as a separate .so): extracted from
#     Debian's libnginx-mod-http-lua .deb. We iterate over whatever .so files
#     the .deb actually ships, so it doesn't matter if NDK is a separate file
#     or compiled into the lua module — both layouts work.
# Load order:
#   10 = NDK (if present), 15 = lua, 90 = VTS.
COPY --from=discover /tmp/modules_path /tmp/modules_path
COPY --from=builder  /build/nginx-src/objs/ngx_http_vhost_traffic_status_module.so /tmp/mods/
COPY --from=builder  /build/lua-extracted/usr/lib/nginx/modules/                   /tmp/lua-mods/

RUN set -eux; \
    MODULES_PATH="$(cat /tmp/modules_path)"; \
    mkdir -p "$MODULES_PATH" /etc/nginx/modules-available /etc/nginx/modules-enabled; \
    # VTS — compiled here.
    mv /tmp/mods/ngx_http_vhost_traffic_status_module.so "$MODULES_PATH/"; \
    chmod 644 "$MODULES_PATH/ngx_http_vhost_traffic_status_module.so"; \
    printf 'load_module %s/ngx_http_vhost_traffic_status_module.so;\n' "$MODULES_PATH" \
        > /etc/nginx/modules-available/90-mod-vts.conf; \
    ln -sf /etc/nginx/modules-available/90-mod-vts.conf /etc/nginx/modules-enabled/90-mod-vts.conf; \
    # NDK — only if Debian shipped it as a separate .so.
    if [ -f /tmp/lua-mods/ndk_http_module.so ]; then \
        mv /tmp/lua-mods/ndk_http_module.so "$MODULES_PATH/"; \
        chmod 644 "$MODULES_PATH/ndk_http_module.so"; \
        printf 'load_module %s/ndk_http_module.so;\n' "$MODULES_PATH" \
            > /etc/nginx/modules-available/10-mod-ndk.conf; \
        ln -sf /etc/nginx/modules-available/10-mod-ndk.conf /etc/nginx/modules-enabled/10-mod-ndk.conf; \
    else \
        echo "NDK is bundled into lua module — no separate load_module needed"; \
    fi; \
    # lua-nginx-module (always present, we asserted above).
    mv /tmp/lua-mods/ngx_http_lua_module.so "$MODULES_PATH/"; \
    chmod 644 "$MODULES_PATH/ngx_http_lua_module.so"; \
    printf 'load_module %s/ngx_http_lua_module.so;\n' "$MODULES_PATH" \
        > /etc/nginx/modules-available/15-mod-lua.conf; \
    ln -sf /etc/nginx/modules-available/15-mod-lua.conf /etc/nginx/modules-enabled/15-mod-lua.conf; \
    rm -rf /tmp/mods /tmp/lua-mods /tmp/modules_path

# Install the CrowdSec nginx bouncer assets at their canonical Debian-package
# paths. The .deb installs the http-level snippet to /etc/nginx/conf.d/ — we
# instead stash it at /usr/share/cs-nginx-bouncer/ so user bind mounts over
# /etc/nginx don't hide it. Users enable it by adding ONE include line to
# their nginx.conf:  include /etc/nginx/crowdsec-include.conf;
# The shim is managed by the entrypoint based on CROWDSEC_BOUNCER_ENABLED.
COPY --from=builder /build/bouncer-extracted /tmp/bouncer
RUN set -eux; \
    mkdir -p /usr/lib/crowdsec/lua /var/lib/crowdsec/lua/templates \
             /etc/crowdsec/bouncers /usr/share/cs-nginx-bouncer; \
    cp -r /tmp/bouncer/usr/lib/crowdsec/lua/.            /usr/lib/crowdsec/lua/; \
    cp -r /tmp/bouncer/var/lib/crowdsec/lua/templates/.  /var/lib/crowdsec/lua/templates/; \
    cp /tmp/bouncer/etc/nginx/conf.d/crowdsec_nginx.conf \
       /usr/share/cs-nginx-bouncer/crowdsec_nginx.conf; \
    cp /tmp/bouncer/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf \
       /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf; \
    # Pre-render the two states the include shim can take. The entrypoint
    # picks one based on CROWDSEC_BOUNCER_ENABLED and symlinks it into place.
    printf 'include /usr/share/cs-nginx-bouncer/crowdsec_nginx.conf;\n' \
        > /usr/share/cs-nginx-bouncer/crowdsec-include.conf.enabled; \
    printf '# CrowdSec bouncer disabled (CROWDSEC_BOUNCER_ENABLED=false)\n' \
        > /usr/share/cs-nginx-bouncer/crowdsec-include.conf.disabled; \
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
# discovered modules path, the bouncer assets are staged, and the stock
# nginx config still validates (the bouncer snippet is NOT auto-loaded;
# it only takes effect once a user nginx.conf includes the shim).
RUN set -eux; \
    MODULES_PATH="$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | sed 's/^--modules-path=//' || echo /usr/lib/nginx/modules)"; \
    # VTS and the lua module must be present. NDK is optional — Debian
    # may bundle it into the lua module rather than ship it separately.
    for so in ngx_http_vhost_traffic_status_module.so ngx_http_lua_module.so; do \
        if [ ! -f "$MODULES_PATH/$so" ]; then \
            echo "SMOKE FAIL: $so not present at $MODULES_PATH" >&2; \
            exit 1; \
        fi; \
    done; \
    for f in /usr/share/cs-nginx-bouncer/crowdsec_nginx.conf \
             /usr/share/cs-nginx-bouncer/crowdsec-include.conf.enabled \
             /usr/share/cs-nginx-bouncer/crowdsec-include.conf.disabled \
             /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf \
             /usr/lib/crowdsec/lua/crowdsec.lua; do \
        if [ ! -e "$f" ]; then \
            echo "SMOKE FAIL: expected bouncer asset $f is missing" >&2; \
            exit 1; \
        fi; \
    done; \
    nginx -t; \
    echo "smoke check OK"

EXPOSE 9010

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
