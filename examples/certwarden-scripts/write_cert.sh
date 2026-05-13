#!/bin/bash
# Certwarden post-issuance hook.
#
# Expected env vars (passed by Certwarden):
#   CERTWARDEN_CERT_NAME     logical cert/domain name
#   CERTWARDEN_PRIVATE_KEY   PEM-encoded private key
#   CERTWARDEN_CERTIFICATE   PEM-encoded fullchain
#
# Additionally:
#   NGINX_UI_HOST            hostname of the nginx-ui container (default: nginx-ui)
#   NGINX_UI_RELOAD_PORT     reload API port              (default: 9010)
#   RELOAD_API_KEY           API key for the reload endpoint  (required)
#   CERT_DIR                 where to write the pair          (default: /certs)
set -euo pipefail

NAME="${CERTWARDEN_CERT_NAME:?CERTWARDEN_CERT_NAME not set}"
CERT="${CERTWARDEN_CERTIFICATE:?CERTWARDEN_CERTIFICATE not set}"
KEY="${CERTWARDEN_PRIVATE_KEY:?CERTWARDEN_PRIVATE_KEY not set}"

NGINX_UI_HOST="${NGINX_UI_HOST:-nginx-ui}"
NGINX_UI_RELOAD_PORT="${NGINX_UI_RELOAD_PORT:-9010}"
CERT_DIR="${CERT_DIR:-/certs}"
: "${RELOAD_API_KEY:?RELOAD_API_KEY must be set}"

dest_dir="${CERT_DIR}/${NAME}"
mkdir -p "$dest_dir"

# Write to temp files, then atomically rename, so nginx never sees a partial
# read mid-rotation.
umask 077
key_tmp="$(mktemp "${dest_dir}/.key.XXXXXX")"
crt_tmp="$(mktemp "${dest_dir}/.crt.XXXXXX")"
printf '%s\n' "$KEY"  > "$key_tmp"
printf '%s\n' "$CERT" > "$crt_tmp"
chmod 640 "$key_tmp" "$crt_tmp"
mv -f "$key_tmp" "${dest_dir}/privkey.pem"
mv -f "$crt_tmp" "${dest_dir}/fullchain.pem"

echo "[write_cert] wrote ${dest_dir}/{privkey,fullchain}.pem"

# Tell nginx to reload via the in-cluster API.
url="http://${NGINX_UI_HOST}:${NGINX_UI_RELOAD_PORT}/reload"
echo "[write_cert] POST ${url}"
response="$(curl -fsS \
    -X POST \
    -H "X-API-Key: ${RELOAD_API_KEY}" \
    --max-time 15 \
    "$url")"
echo "[write_cert] reload response: ${response}"
