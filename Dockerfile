# syntax=docker/dockerfile:1.7
#
# buco7854/nginx — uozi/nginx-ui with stock nginx replaced by OpenResty
# (LuaJIT built in) so the CrowdSec Lua bouncer can run, plus
# lua-resty-prometheus for traffic metrics scraped by Prometheus.
#
# Architecture: nginx-ui (uozi/nginx-ui:latest) is the runtime base. It is
# managed by s6-overlay as PID 1 (NGINX_UI_OFFICIAL_DOCKER=true). We do NOT
# replace the entrypoint — s6 stays in charge. We DO override the nginx
# binary that PATH resolves to by symlinking OpenResty over /usr/sbin/nginx,
# which makes nginx-ui auto-detect the OpenResty build (compat,
# lua-nginx-module, http2/http3, all the modules it ships).
#
# crowdsecurity/openresty is used only as a build-stage copy source:
#   * /usr/local/openresty/                          full OpenResty + LuaJIT
#   * /usr/local/openresty/lualib/plugins/crowdsec/  CrowdSec bouncer lua lib
#   * /var/lib/crowdsec/lua/templates/               ban/captcha HTML templates
#
# Debian codename is detected from /etc/os-release at build time — uozi's
# base tracks nginx:latest, which is on trixie today but will change.

############################################################
# Stage 1: copy source — OpenResty + CrowdSec bouncer assets
############################################################
FROM crowdsecurity/openresty AS openresty-source

############################################################
# Stage 2: final image
############################################################
FROM uozi/nginx-ui:latest

ENV DEBIAN_FRONTEND=noninteractive

# OpenResty itself (binaries, lualib including the CrowdSec bouncer plugin)
# and the bouncer's HTML templates.
COPY --from=openresty-source /usr/local/openresty /usr/local/openresty
COPY --from=openresty-source /var/lib/crowdsec/lua/templates /var/lib/crowdsec/lua/templates

# Add the OpenResty apt repo so we can install openresty-opm, then use opm
# to install lua-resty-prometheus. The Debian release codename is detected
# dynamically — do not hardcode it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg sqlite3; \
    . /etc/os-release; \
    CODENAME="${VERSION_CODENAME:?could not read VERSION_CODENAME from /etc/os-release}"; \
    echo "Detected Debian codename: ${CODENAME}"; \
    install -d /usr/share/keyrings; \
    curl -fsSL https://openresty.org/package/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/openresty.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian ${CODENAME} openresty" \
        > /etc/apt/sources.list.d/openresty.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends openresty-opm; \
    /usr/local/openresty/bin/opm get knyar/nginx-lua-prometheus; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/* /root/.cache

# Make `nginx` on PATH resolve to OpenResty. nginx-ui inspects whatever
# binary is named `nginx` in PATH to decide what features are available;
# pointing it at OpenResty is enough to make it treat the build as
# lua-capable.
RUN ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx

# Bake a default app.ini so the image is usable out of the box. Users
# override by bind-mounting their own at /etc/nginx-ui/app.ini.
COPY app.ini /etc/nginx-ui/app.ini

# Build-time smoke checks:
#   * nginx binary symlink works and reports an OpenResty build
#   * crowdsec lua plugin and HTML templates landed where we expect
#   * lua-resty-prometheus was installed by opm
RUN set -eux; \
    /usr/sbin/nginx -v 2>&1 | grep -qi openresty; \
    test -f /usr/local/openresty/lualib/plugins/crowdsec/crowdsec.lua; \
    test -f /var/lib/crowdsec/lua/templates/ban.html; \
    test -f /usr/local/openresty/site/lualib/prometheus.lua; \
    echo "smoke check OK"

# Network ports: 80/443 are nginx, 9000 is nginx-ui's web UI, 9113 is the
# internal Prometheus scrape endpoint (firewalled to RFC1918 inside nginx).
EXPOSE 80 443 9000 9113

# Do NOT override ENTRYPOINT — s6-overlay /init is inherited from
# uozi/nginx-ui:latest, which is what registers nginx-ui as a managed
# service. NGINX_UI_OFFICIAL_DOCKER=true is also inherited from the base
# and must remain set.
