# nginx-ui-vts

`uozi/nginx-ui` + `nginx-module-vts` (compiled as a dynamic module against the upstream nginx version) + a custom HTML dashboard + a small reload API + `supercronic` for periodic maintenance.

## What's added on top of `uozi/nginx-ui`

| | |
|---|---|
| VTS dynamic module | Built per-image from the exact nginx version shipped by the base. Loaded via `/etc/nginx/modules-enabled/90-mod-vts.conf`. |
| Custom dashboard | `status.html` is baked into the module at build time via `tplToDefine.sh` |
| Reload API | `POST /reload` (auth: `X-API-Key: $RELOAD_API_KEY`) on port `$RELOAD_API_PORT` (default 9010). Also `POST /test` to run `nginx -t`, `GET /health`. |
| Cron | `supercronic` reads `$CRONTAB_FILE` (default `/etc/cron.d/default.crontab`). Set `CRONTAB_FILE=""` to disable. Mount your own file to override. |
| Maintenance scripts | `/usr/local/bin/maintain-nginx-ui-db.sh` (sqlite VACUUM), `/usr/local/bin/security-txt-renew.sh`, `/usr/local/bin/nginx-body-cleanup.sh` |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RELOAD_API_KEY` | _(unset)_ | Required to enable the reload API. If unset, the API is not started. |
| `RELOAD_API_PORT` | `9010` | Port the reload API listens on. |
| `RELOAD_API_LISTEN` | `0.0.0.0` | Bind address. Set to `127.0.0.1` to keep it container-local. |
| `CRONTAB_FILE` | `/etc/cron.d/default.crontab` | Path to crontab read by supercronic. Empty = no cron. |
| `NGINX_UI_DB_PATH` | `/etc/nginx-ui/database.db` | Used by the SQLite maintenance job. |
| `SECURITY_TXT_PATH` | `/var/www/well-known/security.txt` | Used by the security.txt renewal job. |
| `SECURITY_TXT_RENEW_THRESHOLD_DAYS` | `30` | Renew when fewer days remain than this. |
| `SECURITY_TXT_LIFETIME_DAYS` | `365` | New `Expires:` value = now + this many days. |

## Reload API

```bash
curl -fsS -X POST \
     -H "X-API-Key: $RELOAD_API_KEY" \
     http://nginx-ui:9010/reload
# -> {"status":"nginx reloaded"}
```

Endpoints:

| Method | Path | Auth | Action |
|---|---|---|---|
| `GET` | `/health` | none | returns `{"status":"ok"}` |
| `POST` | `/test` | api-key | runs `nginx -t` |
| `POST` | `/reload` | api-key | runs `nginx -s reload` |

## Cron

Mount your own crontab anywhere readable in the container and set `CRONTAB_FILE` to its path:

```yaml
volumes:
  - ./my-crontab:/etc/cron.d/nginx-ui.crontab:ro
environment:
  - CRONTAB_FILE=/etc/cron.d/nginx-ui.crontab
```

Format is standard cron (5 fields). The container ships `/etc/cron.d/default.crontab` with the bundled maintenance jobs — use it as a reference.

## Building locally

```bash
docker build -t nginx-ui-vts \
    --build-arg NGINX_UI_TAG=latest \
    ./nginx-ui-vts
```

See [`../examples/`](../examples) for a full compose stack.
