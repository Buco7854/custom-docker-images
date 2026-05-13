#!/bin/sh
# Sweep abandoned nginx client_body_temp files older than 2 hours.
# Harmless if the directory does not exist (e.g. tmpfs-mounted elsewhere).
set -eu

for dir in /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi /var/lib/nginx/scgi /var/lib/nginx/uwsgi; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -mmin +120 -delete 2>/dev/null || true
done
