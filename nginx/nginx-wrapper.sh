#!/bin/sh
# /usr/sbin/nginx wrapper.
#
# Runs OpenResty with /etc/nginx/nginx.conf as the config file (Debian-
# style, matching where nginx-ui manages files and where the compose
# stack bind-mounts the user's ./conf/). OpenResty's compiled-in default
# is /usr/local/openresty/nginx/conf/nginx.conf, which we don't use.
#
# nginx parses argv left-to-right and the LAST -c wins, so a caller
# passing its own -c (e.g. nginx-ui validating a staged config with
# `nginx -t -c /tmp/staged.conf`) overrides the one we inject here —
# exactly the behaviour the tooling expects.
exec /usr/local/openresty/nginx/sbin/nginx -c /etc/nginx/nginx.conf "$@"
