# nginx-ui-vts

`uozi/nginx-ui` with extra dynamic modules compiled in (VTS, NDK, lua),
the CrowdSec nginx lua bouncer installed, a custom HTML dashboard for VTS,
a small reload API, and `supercronic` for periodic maintenance.

## What's added on top of `uozi/nginx-ui`

| | |
|---|---|
| Dynamic modules | `nginx-module-vts`, `ngx_devel_kit`, `ngx_http_lua_module` — all built per-image against the exact nginx version shipped by the base, with `--with-compat`. |
| VTS dashboard | `status.html` is baked into the VTS module via `tplToDefine.sh` at build time. |
| CrowdSec lua bouncer | `cs-nginx-bouncer` installed at canonical paths (`/usr/local/lua/crowdsec/`, `/var/lib/crowdsec/lua/templates/`, etc.). Off by default — flip on with `CROWDSEC_BOUNCER_ENABLED=true`. Supports AppSec/WAF. |
| Reload API | `POST /reload` (auth: `X-API-Key: $RELOAD_API_KEY`) on `$RELOAD_API_PORT` (default 9010). Also `POST /test` (runs `nginx -t`), `GET /health`. |
| Cron | `supercronic` reads `$CRONTAB_FILE` (default `/etc/cron.d/default.crontab`). Mount your own to override; set empty to disable. |
| Maintenance scripts | `maintain-nginx-ui-db.sh`, `security-txt-renew.sh`, `nginx-body-cleanup.sh` |

## Environment variables

### Core
| Variable | Default | Purpose |
|---|---|---|
| `RELOAD_API_KEY` | _(unset)_ | Required to enable the reload API. |
| `RELOAD_API_PORT` | `9010` | Port the reload API listens on. |
| `RELOAD_API_LISTEN` | `0.0.0.0` | Bind address (set `127.0.0.1` to keep it container-local). |
| `CRONTAB_FILE` | `/etc/cron.d/default.crontab` | Crontab read by supercronic. Empty = no cron. |
| `NGINX_UI_DB_PATH` | `/etc/nginx-ui/database.db` | Used by the SQLite maintenance job. |
| `SECURITY_TXT_PATH` | `/var/www/well-known/security.txt` | Used by the security.txt renewal job. |
| `SECURITY_TXT_RENEW_THRESHOLD_DAYS` | `30` | Renew when fewer days remain. |

### CrowdSec lua bouncer
On each container start, an `.local` override file is rendered at
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local` from these env
vars. The `.local` file takes precedence over the shipped defaults.

| Variable | Default | Purpose |
|---|---|---|
| `CROWDSEC_BOUNCER_ENABLED` | `false` | Master switch. When false, the nginx snippet is moved aside so nginx starts without trying to init the bouncer. |
| `CROWDSEC_LAPI_URL` | _(unset)_ | LAPI URL (e.g. `http://crowdsec:8080`). Required when enabled. |
| `CROWDSEC_BOUNCER_API_KEY` | _(unset)_ | Bouncer API key from `cscli bouncers add`. Required when enabled. |
| `CROWDSEC_MODE` | `stream` | `stream` or `live`. |
| `CROWDSEC_UPDATE_FREQUENCY` | _(unset)_ | Stream mode pull frequency in seconds. |
| `CROWDSEC_BOUNCING_ON_TYPE` | _(unset)_ | `all`, `ban`, or `captcha`. |
| `CROWDSEC_FALLBACK_REMEDIATION` | _(unset)_ | `ban` or `captcha`. |
| `CROWDSEC_EXCLUDE_LOCATION` | _(unset)_ | Comma-separated paths to skip bouncing on. |
| `CROWDSEC_RET_CODE` | _(unset)_ | HTTP code on ban (default 403). |
| `CROWDSEC_REDIRECT_LOCATION` | _(unset)_ | Redirect target on ban. |
| `CROWDSEC_BAN_TEMPLATE_PATH` | `/var/lib/crowdsec/lua/templates/ban.html` | Custom ban page. Mount your own over the default. |
| `CROWDSEC_CAPTCHA_TEMPLATE_PATH` | `/var/lib/crowdsec/lua/templates/captcha.html` | Custom captcha page. Must contain `{{captcha_site_key}}`. |
| `CROWDSEC_CAPTCHA_PROVIDER` | _(unset)_ | `recaptcha`, `hcaptcha`, or `turnstile`. |
| `CROWDSEC_CAPTCHA_SECRET_KEY` | _(unset)_ | Captcha secret key. |
| `CROWDSEC_CAPTCHA_SITE_KEY` | _(unset)_ | Captcha site key. |

### AppSec (WAF)
Set `CROWDSEC_APPSEC_URL` to enable. The other AppSec knobs are passed through if set.

| Variable | Default | Purpose |
|---|---|---|
| `CROWDSEC_APPSEC_URL` | _(unset)_ | AppSec endpoint (e.g. `http://crowdsec:7422`). Empty = AppSec off. |
| `CROWDSEC_APPSEC_FAILURE_ACTION` | _(unset)_ | `passthrough` (default) or `deny`. |
| `CROWDSEC_APPSEC_DROP_UNREADABLE_BODY` | _(unset)_ | `true` to drop HTTP/2/HTTP/3 requests whose body can't be inspected. |
| `CROWDSEC_APPSEC_CONNECT_TIMEOUT` / `SEND_TIMEOUT` / `PROCESS_TIMEOUT` | _(unset)_ | Per-request AppSec timeouts in ms. |
| `CROWDSEC_APPSEC_ALWAYS_SEND` | _(unset)_ | `true` to forward to AppSec even when a decision already exists. |
| `CROWDSEC_APPSEC_SSL_VERIFY` | _(unset)_ | `true`/`false` SSL verification of AppSec endpoint. |

For knobs not exposed here, drop your own `.local` file:
```yaml
volumes:
  - ./my-overrides.conf:/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local:ro
```
(it must come after the entrypoint renders its version — easiest is to set `CROWDSEC_BOUNCER_ENABLED=false` and manage the file entirely yourself.)

## Reload API

```bash
curl -fsS -X POST -H "X-API-Key: $RELOAD_API_KEY" \
     http://nginx-ui:9010/reload
```

| Method | Path | Auth | Action |
|---|---|---|---|
| `GET` | `/health` | none | `{"status":"ok"}` |
| `POST` | `/test` | api-key | runs `nginx -t` |
| `POST` | `/reload` | api-key | runs `nginx -s reload` |

## Cron

Mount your crontab anywhere and point `CRONTAB_FILE` at it:
```yaml
volumes:
  - ./my-crontab:/etc/cron.d/nginx-ui.crontab:ro
environment:
  - CRONTAB_FILE=/etc/cron.d/nginx-ui.crontab
```
Standard 5-field cron format. The shipped `/etc/cron.d/default.crontab` is a reference.

## Building locally

```bash
docker build -t nginx-ui-vts \
    --build-arg NGINX_UI_TAG=latest \
    ./nginx-ui-vts
```

Full compose stack: [`../examples/`](../examples).
