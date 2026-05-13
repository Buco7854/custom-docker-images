#!/bin/sh
# Wrap the upstream nginx-ui entrypoint to also run:
#   - the reload API (if RELOAD_API_KEY is set)
#   - supercronic on $CRONTAB_FILE (if it exists and is non-empty)
#
# Both side processes are started in the background; the upstream init keeps
# running as PID 1 so its signal/health behavior is preserved.

set -eu

cleanup() {
    # forward SIGTERM/SIGINT to children before exiting
    [ -n "${RELOAD_API_PID:-}" ] && kill -TERM "$RELOAD_API_PID" 2>/dev/null || true
    [ -n "${CRON_PID:-}" ]       && kill -TERM "$CRON_PID"       2>/dev/null || true
}
trap cleanup TERM INT

# --- CrowdSec bouncer config (renders .local from env, or disables snippet) -
/usr/local/bin/render-bouncer-conf.sh || {
    echo "[entrypoint] bouncer config rendering failed — aborting" >&2
    exit 1
}

# --- reload API ------------------------------------------------------------
if [ -n "${RELOAD_API_KEY:-}" ]; then
    /usr/local/bin/reload-api.sh &
    RELOAD_API_PID=$!
    echo "[entrypoint] reload-api started (pid=$RELOAD_API_PID)"
else
    echo "[entrypoint] RELOAD_API_KEY not set — reload API disabled"
fi

# --- cron (supercronic) ----------------------------------------------------
if [ -n "${CRONTAB_FILE:-}" ] && [ -s "$CRONTAB_FILE" ]; then
    echo "[entrypoint] starting supercronic with $CRONTAB_FILE"
    /usr/local/bin/supercronic -quiet "$CRONTAB_FILE" &
    CRON_PID=$!
else
    echo "[entrypoint] no crontab file at '${CRONTAB_FILE:-<unset>}' — cron disabled"
fi

# --- hand off to the upstream image ----------------------------------------
# Try common init entrypoints used by uozi/nginx-ui in order of likelihood.
if [ -x /init ]; then
    exec /init "$@"
elif [ -x /docker-entrypoint.sh ]; then
    exec /docker-entrypoint.sh "$@"
elif [ -x /usr/local/bin/dumb-init ]; then
    exec /usr/local/bin/dumb-init -- "$@"
else
    exec "$@"
fi
