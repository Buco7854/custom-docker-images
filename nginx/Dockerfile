# syntax=docker/dockerfile:1.7
#
# buco7854/nginx — uozi/nginx-ui + CrowdSec Lua bouncer + nginx-module-vts.
#
# NO OpenResty (its apt repo lags Debian releases by many months) and NO
# Debian libnginx-mod-* either. uozi/nginx-ui ships nginx.org MAINLINE
# (e.g. 1.29.x), while Debian's lua/ndk modules are built for Debian's
# much older nginx (e.g. 1.26.x). nginx's dynamic-module version check is
# EXACT and is NOT relaxed by --with-compat (that only standardises the
# configure-option signature, never the version), so a Debian module can
# never load here — it fails with "version 1026003 instead of 1029008".
#
# So everything that isn't pure config is compiled from source against
# the EXACT nginx version uozi ships (detected from `nginx -v`),
# --with-compat, in a builder stage on the SAME base (identical
# pcre2/openssl/zlib as runtime):
#
#   1. lua  — LuaJIT (openresty/luajit2) + ngx_devel_kit (NDK) +
#             lua-nginx-module, built against the exact nginx. The
#             lua-resty-core / lua-resty-lrucache pair (MANDATORY for
#             modern lua-nginx-module — init_by_lua loads resty.core or
#             aborts) is vendored onto the lua path from the same upstream
#             default branch so it always matches the module. Used ONLY by
#             the CrowdSec bouncer.
#
#   2. vts  — nginx-module-vts, same exact-nginx compile. Serves the
#             custom HTML dashboard baked in via VTS's tplToDefine.sh —
#             no lua, no Prometheus.
#
# A build-time `nginx -t` that loads all three modules and, inside
# init_by_lua (which forces resty.core to load), requires the bouncer's
# lua deps is the guard: any upstream break fails the BUILD loudly, it
# never silently ships a broken image.
#
# Maintenance posture:
#   * lua stack + VTS: recompiled against whatever nginx version uozi
#     ships, every weekly rebuild — tracks nginx automatically. The lua
#     module set (LuaJIT + NDK + lua-nginx-module + lua-resty-core/
#     -lrucache) moves together on upstream's default branches; pin a
#     one-off reproducible build with the *_REF build-args. The build
#     fails red if a future nginx ever breaks a tracked/pinned component.
#   * CrowdSec bouncer + lua-resty-http/-string: PINNED / luarocks-latest
#     exactly as before, guarded by the same build-time `nginx -t`.
#   * No OpenResty, no nginx wrapper. Stock nginx => nginx-ui just works.

ARG NGINX_UI_TAG=latest

############################################################
# Stage 1: collect the CrowdSec bouncer .deb + pure-lua libs
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS assets

ARG CROWDSEC_GPG_FINGERPRINT=6A89E3C2303A901A889971D3376ED5326E93CD0C
# CrowdSec's packagecloud doesn't track every Debian release, but the
# nginx bouncer .deb is pure lua + config + html (NO native binaries),
# so the release it targets is irrelevant. Asserted below.
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
    \
    mkdir -p /assets/bouncer; \
    dpkg-deb -x "$(ls crowdsec-nginx-bouncer_*.deb)" /assets/bouncer; \
    \
    # lua-resty-http (HTTP client the bouncer uses to reach LAPI) and
    # lua-resty-string (string/crypto helpers): tiny pure-lua libs not in
    # Debian. Installed latest via luarocks — same as you'd do by hand on
    # a baremetal plain-nginx install. Unpinned: the build-time `nginx -t`
    # guard catches any breakage.
    luarocks install lua-resty-http   --tree=/assets/luatree; \
    luarocks install lua-resty-string --tree=/assets/luatree; \
    # Both are pure-lua: luarocks only populates share/lua/5.1 (no C
    # modules, so it never creates lib/lua/5.1). Pre-create it so the
    # final stage's COPY of the C-module search path is a no-op instead
    # of failing, and still carries a .so if a dep ever ships one.
    mkdir -p /assets/luatree/lib/lua/5.1; \
    \
    # Guard: bouncer .deb must stay pure lua/config (no ELF binaries).
    if find /assets/bouncer -type f -exec sh -c 'head -c4 "$1"|grep -q ELF' _ {} \; -print | grep -q .; then \
        echo "FATAL: CrowdSec bouncer .deb now ships native binaries" >&2; exit 1; \
    fi; \
    for f in crowdsec.lua ban.html captcha.html crowdsec_nginx.conf crowdsec-nginx-bouncer.conf; do \
        find /assets/bouncer -name "$f" -print -quit | grep -q . \
            || { echo "FATAL: $f missing from CrowdSec bouncer .deb" >&2; exit 1; }; \
    done

############################################################
# Stage 2: compile LuaJIT + NDK + lua-nginx-module + VTS
#          against the EXACT nginx uozi ships
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS builder

# Everything here is intentionally NOT pinned by default — we track each
# project's default branch so the set stays compatible with whatever
# nginx version uozi ships (upstream fixes nginx-compat there first). The
# lua module set (NDK + lua-nginx-module + lua-resty-core/-lrucache) is
# developed in lockstep on those branches, so tracking them together
# keeps them mutually compatible. The final-stage `nginx -t` guard fails
# the build loudly if a given combination is ever incompatible, so the
# default never silently ships broken. Override any one with its
# --build-arg <NAME>_REF=<tag> for a one-off reproducible build.
ARG VTS_REF=
ARG NDK_REF=
ARG LUA_NGINX_MODULE_REF=
ARG LUA_RESTY_CORE_REF=
ARG LUA_RESTY_LRUCACHE_REF=
ARG LUAJIT2_REF=

# Custom VTS dashboard, baked into the module at compile time via VTS's
# own tplToDefine.sh. This is the ONLY status output — no Prometheus
# format is exposed.
COPY status.html /tmp/status.html

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
    # LuaJIT (OpenResty's fork) — lua-nginx-module's runtime. Build +
    # install to /usr/local; the runtime .so + jit/ lua tree are staged
    # for the final image (the module records libluajit's SONAME and the
    # default lua path points at this exact prefix).
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
    # Bake the custom HTML dashboard into the VTS module. tplToDefine.sh
    # invokes `perl fileToHex.pl` by a BARE relative name, so it only
    # works when run from util/ — run it there in a subshell (our cwd
    # stays /tmp) writing to an absolute path. The script has no `set -e`
    # and exits 0 even when fileToHex.pl can't be found, silently emitting
    # an empty #define that only explodes later at `make`; assert the
    # macro got a real body so any such breakage fails the BUILD loudly
    # right here.
    chmod +x /tmp/vts/util/tplToDefine.sh; \
    ( cd /tmp/vts/util && ./tplToDefine.sh /tmp/status.html ) \
        > /tmp/vts/src/ngx_http_vhost_traffic_status_module_html.h; \
    grep -qF '\x' /tmp/vts/src/ngx_http_vhost_traffic_status_module_html.h \
        || { echo "FATAL: VTS HTML dashboard header is empty (tplToDefine.sh failed)" >&2; exit 1; }; \
    \
    # NDK must precede lua-nginx-module in the configure order.
    cd "nginx-${NGX_VER}"; \
    ./configure --with-compat \
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
    # lua-resty-core / -lrucache are MANDATORY for modern lua-nginx-module
    # (init_by_lua loads resty.core or aborts). Same upstream default
    # branch as the module above => guaranteed-compatible pair.
    clone /tmp/lua-resty-core     https://github.com/openresty/lua-resty-core.git     "${LUA_RESTY_CORE_REF}"; \
    clone /tmp/lua-resty-lrucache https://github.com/openresty/lua-resty-lrucache.git "${LUA_RESTY_LRUCACHE_REF}"; \
    cp -a /tmp/lua-resty-core/lib/.     /assets/luaresty/; \
    cp -a /tmp/lua-resty-lrucache/lib/. /assets/luaresty/

############################################################
# Stage 3: final image
############################################################
ARG NGINX_UI_TAG
FROM uozi/nginx-ui:${NGINX_UI_TAG}

ENV DEBIAN_FRONTEND=noninteractive

RUN grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release \
    || { echo "FATAL: base image is not Debian-family" >&2; exit 1; }

# Only runtime apt deps: lua-cjson (native, the bouncer needs it),
# sqlite3 (host-driven nginx-ui DB maintenance via `docker exec`).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends lua-cjson sqlite3 ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# All three modules are compiled (builder stage) against the EXACT nginx
# uozi ships, alongside the LuaJIT runtime. Install the .so into
# /usr/lib/nginx/modules — that's nginx.org's compiled --modules-path on
# this base, and it's outside /etc/nginx so a host bind mount can't hide
# them. We assert the detected modules-path matches (fail the build
# loudly if upstream ever changes it, since the modules-available files
# hardcode this). The LuaJIT runtime .so + jit/ tree go back to the exact
# /usr/local prefix the module was linked against; ldconfig so the loader
# resolves libluajit's SONAME. Debian's lua-cjson lands under the
# multiarch dir, which is NOT on our nginx.org-prefixed module's default
# lua_package_cpath (Debian's own module had it) — symlink it onto a
# default cpath entry so the bouncer's `require "cjson"` resolves with no
# extra config, exactly as it did with the Debian module.
COPY --from=builder /assets/modules /tmp/mods
COPY --from=builder /assets/luajit  /tmp/luajit
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    DETECTED="$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | sed 's/.*=//')"; \
    [ "${DETECTED:-$MODPATH}" = "$MODPATH" ] \
        || { echo "FATAL: nginx modules-path is $DETECTED, expected $MODPATH" >&2; exit 1; }; \
    mkdir -p "$MODPATH"; \
    install -m644 /tmp/mods/ndk_http_module.so \
        "$MODPATH/ndk_http_module.so"; \
    install -m644 /tmp/mods/ngx_http_lua_module.so \
        "$MODPATH/ngx_http_lua_module.so"; \
    install -m644 /tmp/mods/ngx_http_vhost_traffic_status_module.so \
        "$MODPATH/ngx_http_vhost_traffic_status_module.so"; \
    install -d /usr/local/lib; \
    cp -a /tmp/luajit/libluajit-5.1.so* /usr/local/lib/; \
    mkdir -p /usr/local/share/luajit-2.1; \
    cp -a /tmp/luajit/share/. /usr/local/share/luajit-2.1/; \
    ldconfig; \
    CJSON="$(find /usr/lib /usr/local/lib -name cjson.so -path '*lua/5.1/*' -print -quit)"; \
    [ -n "$CJSON" ] \
        || { echo "FATAL: lua-cjson cjson.so not found" >&2; exit 1; }; \
    install -d /usr/local/lib/lua/5.1; \
    ln -sf "$CJSON" /usr/local/lib/lua/5.1/cjson.so; \
    rm -rf /tmp/mods /tmp/luajit

# CrowdSec bouncer assets at the EXACT paths `apt install
# crowdsec-nginx-bouncer` uses on baremetal: lua at /usr/lib/crowdsec/
# lua, templates at /var/lib/crowdsec/lua/templates, the bouncer config
# at /etc/crowdsec/bouncers/, and the nginx snippet straight into
# conf.d/crowdsec_nginx.conf — placed in the base's config TEMPLATE so
# it's seeded into /etc/nginx exactly like the .deb would, indistinguish-
# able from a baremetal install.
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
# snippet's lua_package_path ends with `;;`, which appends this):
#   * lua-resty-core / -lrucache — MANDATORY for modern lua-nginx-module
#     (init_by_lua loads resty.core or aborts). Built from the same
#     upstream default branch as lua-nginx-module so they always match.
#   * lua-resty-http / -string   — the CrowdSec bouncer's own deps.
COPY --from=builder /assets/luaresty/              /usr/local/share/lua/5.1/
COPY --from=assets  /assets/luatree/share/lua/5.1/ /usr/local/share/lua/5.1/
COPY --from=assets  /assets/luatree/lib/lua/5.1/   /usr/local/lib/lua/5.1/

COPY app.ini /etc/nginx-ui/app.ini

# Seed our drop-ins into the base image's config TEMPLATE
# (/usr/local/etc/nginx). The base already ships an `init-config` s6
# oneshot that runs before nginx and does:
#     [ -z "$(ls -A /etc/nginx)" ] && cp -rp /usr/local/etc/nginx/* /etc/nginx/
# i.e. it seeds /etc/nginx from the template ONLY when /etc/nginx is
# empty, and leaves an existing config completely untouched. By enriching
# that same template we inherit exactly that behaviour — no custom
# entrypoint:
#   * empty /etc/nginx  -> default nginx + nginx-ui proxy + CrowdSec
#                          bouncer + VTS + real-IP + rate-limit, working
#                          out of the box.
#   * existing /etc/nginx (your bind-mounted config) -> NOT touched.
# Only what's REQUIRED for the bouncer/VTS/nginx-ui to work is seeded:
# the load_module drop-ins, real client IP (without it the bouncer acts
# on the Docker gateway IP — useless), the docker resolver, and the VTS
# zone+dashboard. User-policy extras (rate-limit, security.txt) are NOT
# seeded — they live in conf/optional/ and are documented as opt-in.
# (conf.d/crowdsec_nginx.conf was already placed into the template by the
# bouncer step above, exactly as the .deb does on baremetal.)
COPY conf/modules-available/  /usr/share/nginx/modules-available/
COPY conf/conf.d/realip.conf    /usr/local/etc/nginx/conf.d/realip.conf
COPY conf/conf.d/resolver.conf  /usr/local/etc/nginx/conf.d/resolver.conf
COPY conf/conf.d/vts.conf       /usr/local/etc/nginx/conf.d/vts.conf
RUN set -eux; \
    # Debian convention: the real load_module files are image-owned at
    # /usr/share/nginx/modules-available (like the .so files at
    # /usr/lib/nginx/modules — outside /etc/nginx so a bind mount can't
    # hide them); modules-enabled holds numbered symlinks to them.
    # Generate the symlinks into the base's seed template — init-config's
    # `cp -rp` preserves them as symlinks, and the absolute target always
    # exists in the container even when /etc/nginx is bind-mounted.
    mkdir -p /usr/local/etc/nginx/modules-enabled; \
    ln -s /usr/share/nginx/modules-available/mod-http-ndk.conf \
          /usr/local/etc/nginx/modules-enabled/10-mod-http-ndk.conf; \
    ln -s /usr/share/nginx/modules-available/mod-http-lua.conf \
          /usr/local/etc/nginx/modules-enabled/50-mod-http-lua.conf; \
    ln -s /usr/share/nginx/modules-available/mod-http-vhost-traffic-status.conf \
          /usr/local/etc/nginx/modules-enabled/90-mod-http-vhost-traffic-status.conf; \
    test -f /usr/local/etc/nginx/nginx.conf; \
    if ! grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf; then \
        sed -i '1i include /etc/nginx/modules-enabled/*.conf;' \
            /usr/local/etc/nginx/nginx.conf; \
    fi; \
    grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf

# The base's init-config oneshot only seeds a WHOLLY empty /etc/nginx —
# a bring-your-own (populated) /etc/nginx therefore never gets the
# modules-enabled symlinks, so the bouncer/VTS load_module lines are
# missing. Add an s6 oneshot, ordered AFTER init-config and BEFORE
# nginx (init-config -> ensure-modules-enabled -> nginx), that recreates
# them when modules-enabled/ is empty or absent — even on a populated
# /etc/nginx. Scoped to that one dir and only when empty, so a config
# the user manages (e.g. a deliberately removed vts symlink) is never
# clobbered. s6-native: no custom entrypoint. Generated in-build so the
# script is LF regardless of the (Windows) checkout. Fails the build
# loudly if the base ever renames the services we wire into.
RUN <<'EOF'
set -eux
S6=/etc/s6-overlay/s6-rc.d
test -d "$S6/init-config"
test -d "$S6/nginx"
test -f "$S6/nginx/dependencies.d/init-config"
test -d "$S6/user/contents.d"
SVC="$S6/ensure-modules-enabled"
mkdir -p "$SVC/dependencies.d"
printf 'oneshot\n' > "$SVC/type"
printf '%s\n' "$SVC/ensure-modules-enabled.sh" > "$SVC/up"
: > "$SVC/dependencies.d/init-config"
: > "$S6/nginx/dependencies.d/ensure-modules-enabled"
: > "$S6/user/contents.d/ensure-modules-enabled"
cat > "$SVC/ensure-modules-enabled.sh" <<'SCRIPT'
#!/bin/bash
# Seed the modules-enabled symlinks if that dir is empty/absent — even
# when /etc/nginx is a populated bring-your-own bind mount (the base
# init-config only seeds a WHOLLY empty /etc/nginx). Scoped to this one
# dir and only when empty, so a config the user manages (e.g. a
# deliberately removed vts symlink) is never clobbered.
if [ -z "$(ls -A /etc/nginx/modules-enabled 2>/dev/null)" ]; then
    mkdir -p /etc/nginx/modules-enabled
    ln -s /usr/share/nginx/modules-available/mod-http-ndk.conf /etc/nginx/modules-enabled/10-mod-http-ndk.conf
    ln -s /usr/share/nginx/modules-available/mod-http-lua.conf /etc/nginx/modules-enabled/50-mod-http-lua.conf
    ln -s /usr/share/nginx/modules-available/mod-http-vhost-traffic-status.conf /etc/nginx/modules-enabled/90-mod-http-vhost-traffic-status.conf
    echo "[INFO] modules-enabled seeded (ndk/lua/vts symlinks)"
fi
SCRIPT
chmod +x "$SVC/ensure-modules-enabled.sh"
EOF

# Build-time guard: load all three modules + open a VTS zone + run an
# init_by_lua that requires the bouncer's lua deps. init_by_lua forces
# lua-nginx-module to load resty.core (mandatory; aborts if missing), so
# this single `nginx -t` validates the whole compiled stack: the exact
# nginx<->module version match, --with-compat, LuaJIT, the lua path, and
# resty.core/http/string/cjson all resolving. Any breakage fails HERE.
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    { \
      echo "load_module $MODPATH/ndk_http_module.so;"; \
      echo "load_module $MODPATH/ngx_http_lua_module.so;"; \
      echo "load_module $MODPATH/ngx_http_vhost_traffic_status_module.so;"; \
      echo "events{}"; \
      echo "http{ vhost_traffic_status_zone; lua_shared_dict d 1m;"; \
      echo "      init_by_lua_block { require 'resty.http'; require 'resty.string'; require 'cjson' } }"; \
    } > /tmp/probe.conf; \
    nginx -t -c /tmp/probe.conf; \
    rm /tmp/probe.conf; \
    echo "modules load + lua deps resolve — OK"

EXPOSE 80 443 9000 9113

# ENTRYPOINT (s6 /init) and NGINX_UI_OFFICIAL_DOCKER=true inherited
# from uozi/nginx-ui.
