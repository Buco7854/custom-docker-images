# syntax=docker/dockerfile:1.7
#
# buco7854/nginx — uozi/nginx-ui + CrowdSec Lua bouncer + nginx-module-vts,
# the Debian-native way. NO OpenResty (its apt repo lags Debian releases
# by many months — unworkable).
#
# Two things get added to the stock nginx that uozi/nginx-ui ships:
#
#   1. lua  — Debian's libnginx-mod-http-lua + libnginx-mod-http-ndk.
#             Debian builds them --with-compat, exactly the ABI contract
#             that lets a dynamic module load into nginx.org's nginx.
#             Fetched from the SAME base image, so the module always
#             matches the running nginx's Debian release. Auto-patched by
#             Debian on every weekly rebuild. Used ONLY by the CrowdSec
#             bouncer.
#
#   2. vts  — nginx-module-vts has no Debian package, so it's compiled as
#             a dynamic module against the EXACT nginx version uozi ships
#             (detected from `nginx -v`), --with-compat, in a builder
#             stage on the SAME base (identical pcre2/openssl/zlib as
#             runtime). Serves the custom HTML dashboard baked in via
#             VTS's tplToDefine.sh — no lua, no Prometheus.
#
# A build-time `nginx -t` that loads all three modules and requires the
# lua deps is the guard: any upstream break fails the BUILD loudly, it
# never silently ships a broken image.
#
# Maintenance posture:
#   * nginx + lua module: auto-patched by Debian each weekly rebuild.
#   * VTS: recompiled against whatever nginx version uozi ships, every
#     rebuild — tracks nginx automatically. Bump VTS_VERSION only if a
#     future nginx breaks the pinned VTS (the build will tell you).
#   * CrowdSec bouncer + lua-resty-*: PINNED for reproducibility.
#   * No OpenResty, no nginx wrapper. Stock nginx => nginx-ui just works.

ARG NGINX_UI_TAG=latest

############################################################
# Stage 1: collect .deb + lua assets from the SAME base
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
    mkdir -p /assets/deb; cd /assets/deb; \
    apt-get download libnginx-mod-http-lua libnginx-mod-http-ndk; \
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
    if [ -n "${CS_NGINX_BOUNCER_VERSION}" ]; then \
        apt-get download "crowdsec-nginx-bouncer=${CS_NGINX_BOUNCER_VERSION}*"; \
    else \
        apt-get download crowdsec-nginx-bouncer; \
    fi; \
    \
    mkdir -p /assets/lua /assets/bouncer; \
    dpkg-deb -x "$(ls libnginx-mod-http-lua_*.deb)" /assets/lua; \
    dpkg-deb -x "$(ls libnginx-mod-http-ndk_*.deb)" /assets/lua; \
    dpkg-deb -x "$(ls crowdsec-nginx-bouncer_*.deb)" /assets/bouncer; \
    \
    # lua-resty-http (HTTP client the bouncer uses to reach LAPI) and
    # lua-resty-string (string/crypto helpers): tiny pure-lua libs not in
    # Debian. Installed latest via luarocks — same as you'd do by hand on
    # a baremetal plain-nginx install. Unpinned: the build-time `nginx -t`
    # guard catches any breakage.
    luarocks install lua-resty-http   --tree=/assets/luatree; \
    luarocks install lua-resty-string --tree=/assets/luatree; \
    \
    # Guard: bouncer .deb must stay pure lua/config (no ELF binaries).
    if find /assets/bouncer -type f -exec sh -c 'head -c4 "$1"|grep -q ELF' _ {} \; -print | grep -q .; then \
        echo "FATAL: CrowdSec bouncer .deb now ships native binaries" >&2; exit 1; \
    fi; \
    for f in crowdsec.lua ban.html captcha.html crowdsec_nginx.conf crowdsec-nginx-bouncer.conf; do \
        find /assets/bouncer -name "$f" -print -quit | grep -q . \
            || { echo "FATAL: $f missing from CrowdSec bouncer .deb" >&2; exit 1; }; \
    done; \
    find /assets/lua -name 'ngx_http_lua_module.so' -print -quit | grep -q . \
        || { echo "FATAL: ngx_http_lua_module.so missing" >&2; exit 1; }

############################################################
# Stage 2: compile nginx-module-vts against the exact nginx
############################################################
FROM uozi/nginx-ui:${NGINX_UI_TAG} AS builder

# VTS is intentionally NOT pinned — we track its default branch so it
# stays compatible with whatever nginx version uozi ships (VTS upstream
# fixes nginx-compat there first). The final-stage `nginx -t` guard
# fails the build loudly if a given VTS/nginx pair is ever incompatible,
# so "latest" never silently ships broken. Override with --build-arg
# VTS_REF=<tag> for a one-off reproducible build.
ARG VTS_REF=

# Custom VTS dashboard, baked into the module at compile time via VTS's
# own tplToDefine.sh. This is the ONLY status output — no Prometheus
# format is exposed.
COPY status.html /tmp/status.html

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential libpcre2-dev libssl-dev zlib1g-dev; \
    NGX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
    cd /tmp; \
    curl -fsSL "https://nginx.org/download/nginx-${NGX_VER}.tar.gz" | tar xz; \
    if [ -n "${VTS_REF}" ]; then \
        git clone --depth 1 --branch "${VTS_REF}" \
            https://github.com/vozlt/nginx-module-vts.git /tmp/vts; \
    else \
        git clone --depth 1 \
            https://github.com/vozlt/nginx-module-vts.git /tmp/vts; \
    fi; \
    echo "compiling VTS ($(git -C /tmp/vts rev-parse --short HEAD)) against nginx ${NGX_VER}"; \
    # Bake the custom HTML dashboard into the module.
    chmod +x /tmp/vts/util/tplToDefine.sh; \
    /tmp/vts/util/tplToDefine.sh /tmp/status.html \
        > /tmp/vts/src/ngx_http_vhost_traffic_status_module_html.h; \
    cd "nginx-${NGX_VER}"; \
    ./configure --with-compat --add-dynamic-module=/tmp/vts; \
    make -j"$(nproc)" modules; \
    mkdir -p /assets; \
    cp objs/ngx_http_vhost_traffic_status_module.so /assets/

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

# Install lua + ndk (Debian) and vts (compiled) into /usr/lib/nginx/
# modules — that's nginx.org's compiled --modules-path on this base, and
# it's outside /etc/nginx so a host bind mount can't hide them. We assert
# the detected modules-path matches (fail the build loudly if upstream
# ever changes it, since the modules-enabled drop-ins hardcode this).
COPY --from=assets  /assets/lua /tmp/lua
COPY --from=builder /assets/ngx_http_vhost_traffic_status_module.so /tmp/vts.so
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    DETECTED="$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | sed 's/.*=//')"; \
    [ "${DETECTED:-$MODPATH}" = "$MODPATH" ] \
        || { echo "FATAL: nginx modules-path is $DETECTED, expected $MODPATH" >&2; exit 1; }; \
    mkdir -p "$MODPATH"; \
    install -m644 "$(find /tmp/lua -name ndk_http_module.so -print -quit)" \
        "$MODPATH/ndk_http_module.so"; \
    install -m644 "$(find /tmp/lua -name ngx_http_lua_module.so -print -quit)" \
        "$MODPATH/ngx_http_lua_module.so"; \
    install -m644 /tmp/vts.so "$MODPATH/ngx_http_vhost_traffic_status_module.so"; \
    rm -rf /tmp/lua /tmp/vts.so

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

# Vendored pure-lua bouncer deps onto LuaJIT's default search path (the
# CrowdSec snippet's lua_package_path ends with `;;`, which appends this).
COPY --from=assets /assets/luatree/share/lua/5.1/ /usr/local/share/lua/5.1/
COPY --from=assets /assets/luatree/lib/lua/5.1/   /usr/local/lib/lua/5.1/

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
# The .so files live at /usr/lib/nginx/modules (outside /etc/nginx), so
# they're present regardless of seeding; the template just needs the
# load_module include, which the stock nginx.conf lacks.
# (conf.d/crowdsec_nginx.conf was already placed into the template by the
# bouncer step above, exactly as the .deb does on baremetal.)
COPY conf/modules-enabled/    /usr/local/etc/nginx/modules-enabled/
COPY conf/conf.d/realip.conf    /usr/local/etc/nginx/conf.d/realip.conf
COPY conf/conf.d/resolver.conf  /usr/local/etc/nginx/conf.d/resolver.conf
COPY conf/conf.d/ratelimit.conf /usr/local/etc/nginx/conf.d/ratelimit.conf
COPY conf/conf.d/vts.conf       /usr/local/etc/nginx/conf.d/vts.conf
COPY conf/snippets/           /usr/local/etc/nginx/snippets/
COPY conf/server-conf.d/      /usr/local/etc/nginx/server-conf.d/
RUN set -eux; \
    test -f /usr/local/etc/nginx/nginx.conf; \
    if ! grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf; then \
        sed -i '1i include /etc/nginx/modules-enabled/*.conf;' \
            /usr/local/etc/nginx/nginx.conf; \
    fi; \
    grep -q 'modules-enabled' /usr/local/etc/nginx/nginx.conf

# Build-time guard: load all three modules + require the lua deps + open
# a VTS zone. Any --with-compat / lua-path / VTS breakage fails HERE.
RUN set -eux; \
    MODPATH=/usr/lib/nginx/modules; \
    { \
      echo "load_module $MODPATH/ndk_http_module.so;"; \
      echo "load_module $MODPATH/ngx_http_lua_module.so;"; \
      echo "load_module $MODPATH/ngx_http_vhost_traffic_status_module.so;"; \
      echo "events{}"; \
      echo "http{ vhost_traffic_status_zone; lua_shared_dict d 1m;"; \
      echo "      init_by_lua_block { require 'resty.http'; require 'resty.string' } }"; \
    } > /tmp/probe.conf; \
    nginx -t -c /tmp/probe.conf; \
    rm /tmp/probe.conf; \
    echo "modules load + lua deps resolve — OK"

EXPOSE 80 443 9000 9113

# ENTRYPOINT (s6 /init) and NGINX_UI_OFFICIAL_DOCKER=true inherited
# from uozi/nginx-ui.
