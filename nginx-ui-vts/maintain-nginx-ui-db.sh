#!/bin/sh
# VACUUM + integrity-check the nginx-ui SQLite DB.
# Path is configurable via NGINX_UI_DB_PATH.
set -eu

DB="${NGINX_UI_DB_PATH:-/etc/nginx-ui/database.db}"

if [ ! -f "$DB" ]; then
    echo "[db-maint] $DB not found — skipping"
    exit 0
fi

echo "[db-maint] integrity check on $DB"
result="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1)"
echo "[db-maint] integrity: $result"
case "$result" in
    ok) ;;
    *) echo "[db-maint] WARNING: integrity check did not return ok" >&2;;
esac

echo "[db-maint] running VACUUM"
sqlite3 "$DB" 'VACUUM;'
echo "[db-maint] done"
