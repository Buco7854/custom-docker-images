# syntax=docker/dockerfile:1.7
#
# buco7854/nginx = uozi/nginx-ui + CrowdSec Lua bouncer + nginx-module-vts.
#
# Why compile from source: uozi/nginx-ui ships nginx.org MAINLINE. nginx's
# dynamic-module ABI check is EXACT and --with-compat does NOT relax the
# version, so Debian's libnginx-mod-* (built for Debian's older nginx) can
# never load here. So ndk + lua-nginx-module + LuaJIT + VTS are built
# against the EXACT nginx uozi ships (detected from `nginx -v`), on the
# same base. A build-time `nginx -t` loads all three + resolves the
# bouncer's lua deps, so any upstream breakage fails the BUILD, never
# ships silently. The weekly rebuild re-tracks whatever nginx uozi ships;
# pin one-offs with the *_REF build-args.
#
# Repo layout: image/ = baked into this image; example/ = the runnable
# compose stack (NOT used by this build).

ARG NGINX_UI_TAG=latest

#############################################################
# Stage 1 (assets): CrowdSec bouncer .deb + pure-lua deps
#############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS assets

ARG CROWDSEC_GPG_FINGERPRINT=6A89E3C2303A901A889971D3376ED5326E93CD0C
# packagecloud has no per-Debian-release split for this .deb (it's pure
# lua/config/html, asserted below), so the release here is irrelevant.
ARG CROWDSEC_DEBIAN_RELEASE=bookworm
ARG CS_NGINX_BOUNCER_VERSION=

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg luarocks; \
    \
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey -o /tmp/cs.key; \
    fpr="$(gpg --show-keys --with-fingerprint --with-colons /tmp/cs.key \
            | awk -F: '/^fpr/ {print $10; exit}')"; \
    [ "$fpr" = "${CROWDSEC_GPG_FINGERPRINT}" ] \
        || { echo "FATAL: CrowdSec GPG fingerprint mismatch ($fpr)" >&2; exit 1; }; \
    install -d /usr/share/keyrings; \
    gpg --dearmor < /tmp/cs.key > /usr/share/keyrings/crowdsec.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ ${CROWDSEC_DEBIAN_RELEASE} main" \
        > /etc/apt/sources.list.d/crowdsec.list; \
    apt-get update; \
    \
    mkdir -p /assets/deb; cd /assets/deb; \
    if [ -n "${CS_NGINX_BOUNCER_VERSION}" ]; then \
        apt-get download "crowdsec-nginx-bouncer=${CS_NGINX_BOUNCER_VERSION}*"; \
    else \
        apt-get download crowdsec-nginx-bouncer; \
    fi; \
    mkdir -p /assets/bouncer; \
    dpkg-deb -x "$(ls crowdsec-nginx-bouncer_*.deb)" /assets/bouncer; \
    \
    # lua-resty-http / -string: tiny pure-lua deps not in Debian. Latest
    # via luarocks; the build-time `nginx -t` guard catches breakage.
    luarocks install lua-resty-http   --tree=/assets/luatree; \
    luarocks install lua-resty-string --tree=/assets/luatree; \
    # pure-lua => no lib/lua/5.1; pre-create so the final COPY is a no-op.
    mkdir -p /assets/luatree/lib/lua/5.1; \
    \
    # Guard: the .deb must stay pure lua/config (no ELF), and ship the
    # files we depend on.
    if find /assets/bouncer -type f -exec sh -c 'head -c4 "$1"|grep -q ELF' _ {} \; -print | grep -q .; then \
        echo "FATAL: CrowdSec bouncer .deb now ships native binaries" >&2; exit 1; \
    fi; \
    for f in crowdsec.lua ban.html captcha.html crowdsec_nginx.conf crowdsec-nginx-bouncer.conf; do \
        find /assets/bouncer -name "$f" -print -quit | grep -q . \
            || { echo "FATAL: $f missing from CrowdSec bouncer .deb" >&2; exit 1; }; \
    done

#############################################################
# Stage 2 (builder): compile LuaJIT + NDK + lua + VTS
#                     against the EXACT nginx uozi ships
#############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS builder

# Unpinned by default: track each project's default branch (upstream
# fixes nginx-compat there first; the lua set moves in lockstep). The
# final `nginx -t` guard fails the build if a combo is incompatible.
# Override any one with --build-arg <NAME>_REF=<tag>.
ARG VTS_REF=
ARG NDK_REF=
ARG LUA_NGINX_MODULE_REF=
ARG LUA_RESTY_CORE_REF=
ARG LUA_RESTY_LRUCACHE_REF=
ARG LUAJIT2_REF=

# Custom VTS dashboard, baked into the module at compile time. Only
# status output — no Prometheus format.
COPY image/status.html /tmp/status.html

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential perl libpcre2-dev libssl-dev zlib1g-dev; \
    NGX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
    clone() { \
        if [ -n "$3" ]; then git clone --depth 1 --branch "$3" "$2" "$1"; \
        else git clone --depth 1 "$2" "$1"; fi; \
    }; \
    cd /tmp; \
    curl -fsSL "https://nginx.org/download/nginx-${NGX_VER}.tar.gz" | tar xz; \
    \
    # LuaJIT (OpenResty fork) — lua-nginx-module's runtime. Installed to
    # the exact /usr/local prefix the module links against.
    clone /tmp/luajit2 https://github.com/openresty/luajit2.git "${LUAJIT2_REF}"; \
    make -C /tmp/luajit2 -j"$(nproc)"; \
    make -C /tmp/luajit2 install PREFIX=/usr/local; \
    ldconfig; \
    export LUAJIT_LIB=/usr/local/lib; \
    export LUAJIT_INC=/usr/local/include/luajit-2.1; \
    \
    clone /tmp/ndk              https://github.com/vision5/ngx_devel_kit.git      "${NDK_REF}"; \
    clone /tmp/lua-nginx-module https://github.com/openresty/lua-nginx-module.git "${LUA_NGINX_MODULE_REF}"; \
    clone /tmp/vts              https://github.com/vozlt/nginx-module-vts.git     "${VTS_REF}"; \
    echo "compiling against nginx ${NGX_VER}:" \
         "luajit2($(git -C /tmp/luajit2 rev-parse --short HEAD))" \
         "ndk($(git -C /tmp/ndk rev-parse --short HEAD))" \
         "lua-nginx-module($(git -C /tmp/lua-nginx-module rev-parse --short HEAD))" \
         "vts($(git -C /tmp/vts rev-parse --short HEAD))"; \
    \
    # tplToDefine.sh calls `perl fileToHex.pl` by bare name (only works
    # from util/); it has no `set -e` and exits 0 even on failure,
    # emitting an empty #define — assert the macro got a real body.
    chmod +x /tmp/vts/util/tplToDefine.sh; \
    ( cd /tmp/vts/util && ./tplToDefine.sh /tmp/status.html ) \
        > /tmp/vts/src/ngx_http_vhost_traffic_status_module_html.h; \
    grep -qF '\x' /tmp/vts/src/ngx_http_vhost_traffic_status_module_html.h \
        || { echo "FATAL: VTS HTML dashboard header is empty (tplToDefine.sh failed)" >&2; exit 1; }; \
    \
    # NDK must precede lua-nginx-module. --with-http_ssl_module is
    # REQUIRED: lua-nginx-module gates its lua_ssl_* directives +
    # TLS-cosocket behind NGX_HTTP_SSL at COMPILE time, and --with-compat
    # does NOT define it — without this, nginx rejects the CrowdSec
    # snippet at runtime ("unknown directive lua_ssl_trusted_certificate").
    cd "nginx-${NGX_VER}"; \
    ./configure --with-compat --with-http_ssl_module \
        --add-dynamic-module=/tmp/ndk \
        --add-dynamic-module=/tmp/lua-nginx-module \
        --add-dynamic-module=/tmp/vts; \
    make -j"$(nproc)" modules; \
    \
    mkdir -p /assets/modules /assets/luajit /assets/luaresty; \
    cp objs/ndk_http_module.so \
       objs/ngx_http_lua_module.so \
       objs/ngx_http_vhost_traffic_status_module.so /assets/modules/; \
    cp -a /usr/local/lib/libluajit-5.1.so* /assets/luajit/; \
    mkdir -p /assets/luajit/share; \
    cp -a /usr/local/share/luajit-2.1/.    /assets/luajit/share/; \
    \
    # lua-resty-core / -lrucache: MANDATORY for modern lua-nginx-module
    # (init_by_lua loads resty.core or aborts). Same upstream branch as
    # the module => guaranteed-compatible pair.
    clone /tmp/lua-resty-core     https://github.com/openresty/lua-resty-core.git     "${LUA_RESTY_CORE_REF}"; \
    clone /tmp/lua-resty-lrucache https://github.com/openresty/lua-resty-lrucache.git "${LUA_RESTY_LRUCACHE_REF}"; \
    cp -a /tmp/lua-resty-core/lib/.     /assets/luaresty/; \
    cp -a /tmp/lua-resty-lrucache/lib/. /assets/luaresty/

#############################################################
# Stage 3: final image
#############################################################
ARG NGINX_UI_TAG
FROM uozi/nginx-ui:${NGINX_UI_TAG}

ENV DEBIAN_FRONTEND=noninteractive

RUN grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release \
    || { echo "FATAL: base image is not Debian-family" >&2; exit 1; }

# Runtime deps only: lua-cjson (the bouncer needs it), sqlite3 (host-side
# nginx-ui DB maintenance via `docker exec`).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends lua-cjson sqlite3 ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# Install the .so into /usr/lib/nginx/modules (nginx.org's --modules-path
# on this base; outside /etc/nginx so a bind mount can't hide them).
# Assert that path so the build fails if upstream ever changes it.
# LuaJIT runtime goes back to the exact /usr/local prefix it linked
# against. Debian's lua-cjson lands on the multiarch dir, off our
# nginx.org module's default cpath — symlink it so `require "cjson"`
# resolves with no extra config.
COPY --from=builder /assets/modules /tmp/mods
COPY --from=builder /assets/luajit  /tmp/luajit
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    DETECTED="$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | sed 's/.*=//')"; \
    [ "${DETECTED:-$MODPATH}" = "$MODPATH" ] \
        || { echo "FATAL: nginx modules-path is $DETECTED, expected $MODPATH" >&2; exit 1; }; \
    mkdir -p "$MODPATH"; \
    install -m644 /tmp/mods/ndk_http_module.so                     "$MODPATH/ndk_http_module.so"; \
    install -m644 /tmp/mods/ngx_http_lua_module.so                 "$MODPATH/ngx_http_lua_module.so"; \
    install -m644 /tmp/mods/ngx_http_vhost_traffic_status_module.so "$MODPATH/ngx_http_vhost_traffic_status_module.so"; \
    install -d /usr/local/lib; \
    cp -a /tmp/luajit/libluajit-5.1.so* /usr/local/lib/; \
    mkdir -p /usr/local/share/luajit-2.1; \
    cp -a /tmp/luajit/share/. /usr/local/share/luajit-2.1/; \
    ldconfig; \
    CJSON="$(find /usr/lib /usr/local/lib -name cjson.so -path '*lua/5.1/*' -print -quit)"; \
    [ -n "$CJSON" ] || { echo "FATAL: lua-cjson cjson.so not found" >&2; exit 1; }; \
    install -d /usr/local/lib/lua/5.1; \
    ln -sf "$CJSON" /usr/local/lib/lua/5.1/cjson.so; \
    rm -rf /tmp/mods /tmp/luajit

# CrowdSec bouncer assets at the EXACT baremetal `apt install` paths:
# lua at /usr/lib/crowdsec/lua, templates at /var/lib/crowdsec/lua/
# templates, config at /etc/crowdsec/bouncers/, and the nginx snippet
# into the base's config TEMPLATE so it seeds into /etc/nginx like the
# .deb would.
COPY --from=assets /assets/bouncer /tmp/bouncer
RUN set -eux; \
    mkdir -p /usr/lib/crowdsec/lua /var/lib/crowdsec/lua/templates \
             /etc/crowdsec/bouncers /usr/local/etc/nginx/conf.d; \
    cp -r "$(dirname "$(find /tmp/bouncer -name crowdsec.lua -print -quit)")/." \
          /usr/lib/crowdsec/lua/; \
    cp -r "$(dirname "$(find /tmp/bouncer -name ban.html -print -quit)")/." \
          /var/lib/crowdsec/lua/templates/; \
    cp "$(find /tmp/bouncer -name crowdsec_nginx.conf -print -quit)" \
       /usr/local/etc/nginx/conf.d/crowdsec_nginx.conf; \
    cp "$(find /tmp/bouncer -name crowdsec-nginx-bouncer.conf -print -quit)" \
       /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf; \
    rm -rf /tmp/bouncer

# Vendored pure-lua deps onto LuaJIT's default search path (the CrowdSec
# snippet's lua_package_path ends with `;;`): resty.core/-lrucache
# (mandatory for the module) + resty.http/-string (the bouncer's deps).
COPY --from=builder /assets/luaresty/              /usr/local/share/lua/5.1/
COPY --from=assets  /assets/luatree/share/lua/5.1/ /usr/local/share/lua/5.1/
COPY --from=assets  /assets/luatree/lib/lua/5.1/   /usr/local/lib/lua/5.1/

COPY image/app.ini /etc/nginx-ui/app.ini

# Seed our drop-ins into the base's config TEMPLATE (/usr/local/etc/
# nginx). The base's `init-config` s6 oneshot copies the template into
# /etc/nginx ONLY when /etc/nginx is empty, and never touches an existing
# config — we inherit exactly that, no custom entrypoint. Only what the
# bouncer/nginx-ui REQUIRE is seeded (real-IP, resolver, load_module
# symlinks). The VTS *zone* config is opt-in (an example under
# image/conf/optional/) — but its load_module symlink IS seeded, so the
# module is loaded-but-inert until you add a zone. User-policy extras
# likewise stay in image/conf/optional/. Debian convention: real
# load_module files are image-owned at /usr/share/nginx/modules-available
# (like the .so, outside /etc/nginx); modules-enabled holds numbered
# symlinks (NDK 10- before lua 50-; VTS 90- independent).
COPY image/conf/modules-available/ /usr/share/nginx/modules-available/
COPY image/conf/conf.d/realip.conf   /usr/local/etc/nginx/conf.d/realip.conf
COPY image/conf/conf.d/resolver.conf /usr/local/etc/nginx/conf.d/resolver.conf
RUN set -eux; \
    mkdir -p /usr/local/etc/nginx/modules-enabled; \
    ln -s /usr/share/nginx/modules-available/mod-http-ndk.conf \
          /usr/local/etc/nginx/modules-enabled/10-mod-http-ndk.conf; \
    ln -s /usr/share/nginx/modules-available/mod-http-lua.conf \
          /usr/local/etc/nginx/modules-enabled/50-mod-http-lua.conf; \
    ln -s /usr/share/nginx/modules-available/mod-http-vhost-traffic-status.conf \
          /usr/local/etc/nginx/modules-enabled/90-mod-http-vhost-traffic-status.conf; \
    test -f /usr/local/etc/nginx/nginx.conf; \
    grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf \
        || sed -i '1i include /etc/nginx/modules-enabled/*.conf;' /usr/local/etc/nginx/nginx.conf; \
    grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf

# init-config only seeds a WHOLLY empty /etc/nginx, so a bring-your-own
# (populated) /etc/nginx never gets the integration drop-ins. Add an s6
# oneshot ordered init-config -> ensure-integration -> nginx that
# self-heals them: each modules-enabled symlink AND each required
# conf.d file is (re)created only if missing — idempotent, never
# clobbers anything you manage. s6-native, no entrypoint; generated
# in-build so the script is LF. Fails the build if the base renames the
# services we wire into.
RUN <<'EOF'
set -eux
S6=/etc/s6-overlay/s6-rc.d
test -d "$S6/init-config"
test -d "$S6/nginx"
test -f "$S6/nginx/dependencies.d/init-config"
test -d "$S6/user/contents.d"
SVC="$S6/ensure-integration"
mkdir -p "$SVC/dependencies.d"
printf 'oneshot\n' > "$SVC/type"
printf '%s\n' "$SVC/ensure-integration.sh" > "$SVC/up"
: > "$SVC/dependencies.d/init-config"
: > "$S6/nginx/dependencies.d/ensure-integration"
: > "$S6/user/contents.d/ensure-integration"
cat > "$SVC/ensure-integration.sh" <<'SCRIPT'
#!/bin/bash
# Self-heal the integration drop-ins in a bring-your-own /etc/nginx
# (init-config only seeds a WHOLLY empty one). Per-item & idempotent —
# an existing file/symlink you manage is never clobbered.

# load_module symlinks — real files are image-owned in modules-available
mkdir -p /etc/nginx/modules-enabled
MA=/usr/share/nginx/modules-available
link() {
    t="/etc/nginx/modules-enabled/$2"
    [ -e "$t" ] || [ -L "$t" ] || { ln -s "$MA/$1" "$t"; echo "[INFO] linked $2"; }
}
link mod-http-ndk.conf                  10-mod-http-ndk.conf
link mod-http-lua.conf                  50-mod-http-lua.conf
link mod-http-vhost-traffic-status.conf 90-mod-http-vhost-traffic-status.conf

# required conf.d drop-ins — source is the image's seed template, always
# present even with /etc/nginx bind-mounted
mkdir -p /etc/nginx/conf.d
T=/usr/local/etc/nginx/conf.d
seed() {
    d="/etc/nginx/conf.d/$1"
    [ -e "$d" ] && return 0
    [ -e "$T/$1" ] || { echo "[WARN] template conf.d/$1 missing, skipped"; return 0; }
    cp -p "$T/$1" "$d" && echo "[INFO] seeded conf.d/$1"
}
seed crowdsec_nginx.conf
seed realip.conf
seed resolver.conf
SCRIPT
chmod +x "$SVC/ensure-integration.sh"
EOF

# Build guard: load all three modules, open a VTS zone, and run an
# init_by_lua that requires the bouncer's deps (forces resty.core). This
# one `nginx -t` validates the exact nginx<->module match, --with-compat,
# LuaJIT, the lua path, lua ssl, and resty.core/http/string/cjson.
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    { \
      echo "load_module $MODPATH/ndk_http_module.so;"; \
      echo "load_module $MODPATH/ngx_http_lua_module.so;"; \
      echo "load_module $MODPATH/ngx_http_vhost_traffic_status_module.so;"; \
      echo "events{}"; \
      echo "http{ vhost_traffic_status_zone; lua_shared_dict d 1m;"; \
      echo "      lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;"; \
      echo "      init_by_lua_block { require 'resty.http'; require 'resty.string'; require 'cjson' } }"; \
    } > /tmp/probe.conf; \
    nginx -t -c /tmp/probe.conf; \
    rm /tmp/probe.conf; \
    echo "modules load + lua ssl + deps resolve — OK"

EXPOSE 80 443 9000 9113

# ENTRYPOINT (s6 /init) + NGINX_UI_OFFICIAL_DOCKER=true inherited from
# uozi/nginx-ui.
