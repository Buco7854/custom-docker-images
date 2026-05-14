#!/bin/sh
# Bump the Expires: line in a security.txt file when it's within the
# renewal-threshold window. Idempotent; safe to run daily.
#
# Env:
#   SECURITY_TXT_PATH                (default /var/www/well-known/security.txt)
#   SECURITY_TXT_RENEW_THRESHOLD_DAYS (default 30)
#   SECURITY_TXT_LIFETIME_DAYS       (default 365)
set -eu

FILE="${SECURITY_TXT_PATH:-/var/www/well-known/security.txt}"
THRESHOLD="${SECURITY_TXT_RENEW_THRESHOLD_DAYS:-30}"
LIFETIME="${SECURITY_TXT_LIFETIME_DAYS:-365}"

if [ ! -f "$FILE" ]; then
    echo "[security-txt] $FILE not found — skipping"
    exit 0
fi

current="$(grep -i '^Expires:' "$FILE" | head -n1 | sed 's/^[^:]*:[ ]*//' | tr -d '\r')"
if [ -z "$current" ]; then
    echo "[security-txt] no Expires: line in $FILE — skipping"
    exit 0
fi

if ! current_epoch="$(date -u -d "$current" +%s 2>/dev/null)"; then
    echo "[security-txt] could not parse Expires: '$current'" >&2
    exit 1
fi

now_epoch="$(date -u +%s)"
remaining_days=$(( (current_epoch - now_epoch) / 86400 ))

if [ "$remaining_days" -gt "$THRESHOLD" ]; then
    echo "[security-txt] $remaining_days days left (> $THRESHOLD) — no renewal needed"
    exit 0
fi

new_expiry="$(date -u -d "+${LIFETIME} days" +%Y-%m-%dT%H:%M:%S.000Z)"
echo "[security-txt] renewing: $current -> $new_expiry"

tmp="$(mktemp)"
sed "s|^Expires:.*|Expires: ${new_expiry}|I" "$FILE" > "$tmp"
mv "$tmp" "$FILE"
echo "[security-txt] updated $FILE"
