#!/bin/sh
# Tiny HTTP API to reload nginx from outside the container.
#
# Single endpoint:  POST /reload   (requires header X-API-Key: $RELOAD_API_KEY)
# Also exposes:     GET  /health   (no auth, useful for healthchecks)
#
# Implementation: socat fork-listens on $RELOAD_API_PORT and execs this
# same script with `--handle` for every connection.

set -eu

if [ "${1:-}" = "--handle" ]; then
    read -r method path _ || exit 0
    method="${method%$(printf '\r')}"
    path="${path%$(printf '\r')}"

    api_key=""
    while IFS= read -r line; do
        line="${line%$(printf '\r')}"
        [ -z "$line" ] && break
        case "$line" in
            X-API-Key:*|x-api-key:*|X-Api-Key:*)
                api_key="${line#*:}"
                api_key="${api_key# }"
                ;;
        esac
    done

    respond() {
        status="$1"; body="$2"
        len="$(printf '%s' "$body" | wc -c)"
        printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
            "$status" "$len" "$body"
    }

    if [ "$method" = "GET" ] && [ "$path" = "/health" ]; then
        respond "200 OK" '{"status":"ok"}'
        exit 0
    fi

    if [ -z "${RELOAD_API_KEY:-}" ] || [ "$api_key" != "$RELOAD_API_KEY" ]; then
        respond "403 Forbidden" '{"error":"unauthorized"}'
        exit 0
    fi

    case "$method $path" in
        "POST /reload")
            if out="$(nginx -s reload 2>&1)"; then
                respond "200 OK" '{"status":"nginx reloaded"}'
            else
                # escape quotes/newlines minimally for JSON
                esc="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/"/\\"/g')"
                respond "500 Internal Server Error" "{\"error\":\"reload failed\",\"detail\":\"${esc}\"}"
            fi
            ;;
        "POST /test")
            if out="$(nginx -t 2>&1)"; then
                esc="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/"/\\"/g')"
                respond "200 OK" "{\"status\":\"ok\",\"detail\":\"${esc}\"}"
            else
                esc="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/"/\\"/g')"
                respond "400 Bad Request" "{\"error\":\"config test failed\",\"detail\":\"${esc}\"}"
            fi
            ;;
        *)
            respond "404 Not Found" '{"error":"not found"}'
            ;;
    esac
    exit 0
fi

# --- server mode -----------------------------------------------------------
: "${RELOAD_API_PORT:=9010}"
: "${RELOAD_API_LISTEN:=0.0.0.0}"

if [ -z "${RELOAD_API_KEY:-}" ]; then
    echo "[reload-api] RELOAD_API_KEY not set — refusing to start" >&2
    exit 1
fi

echo "[reload-api] listening on ${RELOAD_API_LISTEN}:${RELOAD_API_PORT}"
exec socat \
    TCP-LISTEN:"${RELOAD_API_PORT}",bind="${RELOAD_API_LISTEN}",reuseaddr,fork \
    EXEC:"$0 --handle"
