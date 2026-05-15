#!/bin/bash
# Certwarden post-issuance hook.
#
# Run by Certwarden after it issues / renews a certificate. Writes the
# cert pair to /certs/<CERTIFICATE_NAME>/ (the container's view; the host
# dir /etc/ssl/domains is bind-mounted there and read by nginx at
# /etc/ssl/domains) and calls nginx-ui's reload API to pick it up.
#
# Required env vars (passed in by Certwarden + .env):
#   CERTIFICATE_PEM     PEM-encoded fullchain
#   PRIVATE_KEY_PEM     PEM-encoded private key
#   CERTIFICATE_NAME    logical cert/domain name (used for the directory)
#   NGINX_UI_API_KEY    matches [auth] ApiKey in nginx-ui/app.ini
#
# Optional:
#   NGINX_UI_HOST       default: nginx (compose service name)
#   NGINX_UI_PORT       default: 80   (nginx-ui served from the proxy itself)
#   CERT_ROOT           default: /certs (certwarden's mount of the host's
#                        /etc/ssl/domains)
set -euo pipefail

log() {
    printf '%s [write_cert] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

: "${CERTIFICATE_PEM:?CERTIFICATE_PEM not set}"
: "${PRIVATE_KEY_PEM:?PRIVATE_KEY_PEM not set}"
: "${CERTIFICATE_NAME:?CERTIFICATE_NAME not set}"
: "${NGINX_UI_API_KEY:?NGINX_UI_API_KEY not set}"

NGINX_UI_HOST="${NGINX_UI_HOST:-nginx}"
NGINX_UI_PORT="${NGINX_UI_PORT:-80}"
CERT_ROOT="${CERT_ROOT:-/certs}"

dest_dir="${CERT_ROOT}/${CERTIFICATE_NAME}"
log "writing cert pair to ${dest_dir}/"
mkdir -p "$dest_dir" || die "could not create ${dest_dir}"

# Write to temp files first, then atomically rename — avoids nginx ever
# reading half a fullchain mid-rotation.
umask 077
key_tmp="$(mktemp "${dest_dir}/.key.XXXXXX")"
crt_tmp="$(mktemp "${dest_dir}/.crt.XXXXXX")"
trap 'rm -f "$key_tmp" "$crt_tmp"' EXIT

printf '%s\n' "$PRIVATE_KEY_PEM"  > "$key_tmp" || die "writing key failed"
printf '%s\n' "$CERTIFICATE_PEM"  > "$crt_tmp" || die "writing fullchain failed"

chmod 640 "$key_tmp" || die "chmod 640 on key failed"
chmod 644 "$crt_tmp" || die "chmod 644 on fullchain failed"

mv -f "$key_tmp" "${dest_dir}/privkey.pem"   || die "rename key failed"
mv -f "$crt_tmp" "${dest_dir}/fullchain.pem" || die "rename fullchain failed"
trap - EXIT

log "wrote ${dest_dir}/{privkey,fullchain}.pem"

# Reload nginx via nginx-ui's API. Both containers live on proxy_net, so
# the service name `nginx` resolves over the compose DNS.
url="http://${NGINX_UI_HOST}:${NGINX_UI_PORT}/api/nginx/reload"
log "POST ${url}"

response="$(curl -fsS -X POST \
    -H "X-API-Key: ${NGINX_UI_API_KEY}" \
    --max-time 15 \
    "$url")" || die "reload API call failed"

log "reload response: ${response}"
log "done"
