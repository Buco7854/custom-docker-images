# buco7854/nginx — homelab reverse-proxy stack

`buco7854/nginx` is `uozi/nginx-ui:latest` with stock nginx replaced by
OpenResty (LuaJIT built in) so the CrowdSec Lua bouncer can run, plus
`lua-resty-prometheus` for traffic metrics. This repo also contains a
ready-to-run `docker-compose.yml` that wires nginx together with CrowdSec
(engine + web UI), Prometheus, Grafana, and Certwarden into a complete
reverse-proxy stack.

## Image

| Image | Source | Schedule |
|-------|--------|----------|
| `buco7854/nginx:latest`  | this repo's [`Dockerfile`](./Dockerfile) | Weekly Sun 00:00 UTC |
| `buco7854/nginx:<sha>`   | tagged on every push to `main`           | per-commit            |

Architecture: `uozi/nginx-ui:latest` is the runtime base. s6-overlay (`/init`)
stays as PID 1 and continues to manage nginx-ui as a service. OpenResty
binaries are copied in from `crowdsecurity/openresty` (build-stage source
only, never run as a container) and `/usr/sbin/nginx` is symlinked to the
OpenResty binary so nginx-ui auto-detects the lua-capable build. The
Debian release codename is detected from `/etc/os-release` at build time —
nothing is hardcoded, so the image follows whatever nginx-ui's base
becomes.

OpenResty's compiled-in default config path is
`/usr/local/openresty/nginx/conf/nginx.conf`. Rather than mess with
OpenResty's installation directory, the image installs `/usr/sbin/nginx`
as a tiny wrapper that runs OpenResty with `-c /etc/nginx/nginx.conf`,
and `app.ini` points `SbinPath` at the wrapper so every nginx-ui call
(`nginx -t`, `nginx -s reload`, etc.) inherits the flag. nginx parses
argv left-to-right and the last `-c` wins, so a caller passing its own
`-c` (e.g. validating a staged config) cleanly overrides ours.

## Stack overview

```
Internet
    │ 80/443
    ▼
┌─────────────────────────────────────────────────────┐
│  nginx (buco7854/nginx)                             │
│  OpenResty + CrowdSec Lua bouncer + nginx-ui        │
│  nginx-ui web UI accessible via port 80             │
└──────┬──────────────┬───────────────────────────────┘
       │              │
       │ logs         │ /metrics :9113
       ▼              ▼
┌──────────┐    ┌────────────┐
│ crowdsec │    │ prometheus │──── grafana :3001
│ LAPI     │    └────────────┘
│ :8080    │
└────┬─────┘
     │
     ▼
┌──────────────┐
│ crowdsec-ui  │
│ :3000        │
└──────────────┘

certwarden :4055 ──writes certs──▶ ./ssl/
                 ──POST reload──▶  nginx /api/nginx/reload
```

Everything except 80/443 binds to `127.0.0.1` only — nothing on the LAN
can talk to LAPI, Grafana, the CrowdSec UI, Prometheus, or Certwarden's
admin port. All services share the `proxy_net` bridge network, so they
resolve each other by service name (`nginx`, `crowdsec`, `prometheus`,
etc.).

## First-time setup

1. **Clone and configure.**
   ```bash
   git clone https://github.com/buco7854/custom-docker-images
   cd custom-docker-images/nginx
   cp .env.example .env
   $EDITOR .env
   ```
2. **Drop in your existing nginx config.** Copy your Debian-style tree
   (`sites-available/`, `sites-enabled/`, plus any custom files) into
   `./conf/` next to the seed `nginx.conf`. The structure is
   preserved 1:1.
3. **Seed certs.** Either drop existing cert pairs into
   `./ssl/<domain>/{fullchain,privkey}.pem`, or let Certwarden write
   them on first issuance.
4. **Match the API keys.** Edit `nginx-ui/app.ini` (created on first
   start) so that `[auth] ApiKey` matches `NGINX_UI_API_KEY` in `.env`.
   Edit `crowdsec/bouncer.conf` so `API_KEY` matches
   `CROWDSEC_BOUNCER_API_KEY` in `.env`.
5. **Bring it up.**
   ```bash
   docker compose up -d
   ```
   The `BOUNCER_KEY_nginx` env var on the CrowdSec service auto-registers
   that bouncer key on first start, so the nginx bouncer authenticates
   immediately.
6. **Generate the web-UI bouncer key.**
   ```bash
   docker compose exec crowdsec cscli bouncers add crowdsec-web-ui
   ```
   Paste the key into `.env` as `CROWDSEC_WEB_UI_API_KEY`, then:
   ```bash
   docker compose restart crowdsec-ui
   ```
7. **Open the UIs.**
   - nginx-ui — http://localhost (served on port 80 via the proxy itself)
   - Grafana — http://localhost:3001 (import dashboard ID `10442` for
     nginx metrics)
   - CrowdSec web UI — http://localhost:3000

## Certwarden integration

Certwarden runs its post-issuance hook script inside its own container.
The compose file already mounts `./scripts:/scripts:ro` into Certwarden,
so configure Certwarden to run `/scripts/write_cert.sh` after issuance.

The script expects these env vars (which Certwarden passes, plus
`NGINX_UI_API_KEY` from your `.env`):

| Var               | Source                                |
|-------------------|---------------------------------------|
| `CERTIFICATE_PEM` | Certwarden — PEM-encoded fullchain    |
| `PRIVATE_KEY_PEM` | Certwarden — PEM-encoded private key  |
| `CERTIFICATE_NAME`| Certwarden — logical cert/domain name |
| `NGINX_UI_API_KEY`| `.env`                                |

The hook writes `fullchain.pem` and `privkey.pem` under
`/etc/ssl/domains/<CERTIFICATE_NAME>/` (which is `./ssl/` on the host,
bind-mounted into nginx read-only) and then `POST`s
`http://nginx/api/nginx/reload` with the `X-API-Key` header to trigger
`nginx -s reload`.

## Nginx config migration

The Debian layout is preserved — `conf.d/`, `sites-available/`,
`sites-enabled/`, `server-conf.d/`, and `snippets/` all work exactly as
they did on a bare-metal Debian host. To migrate:

- **Drop your existing tree into `./conf/`.** Don't merge —
  literally copy the directory.
- **Remove `load_module ...` lines.** OpenResty has Lua built in; no
  dynamic modules to load.
- **Strip systemd-isms** if any leaked in (`PIDFile=`, etc.).
- **Update cert paths.** Where you had `ssl_certificate /certs/<domain>/...`,
  change to `ssl_certificate /etc/ssl/domains/<domain>/fullchain.pem;`
  (same for `ssl_certificate_key /etc/ssl/domains/<domain>/privkey.pem;`).
- **Keep includes intact.** Per-server `include /etc/nginx/server-conf.d/*.conf;`
  and `include /etc/nginx/snippets/...;` lines work unchanged.

Real-IP directives are already in `nginx.conf` (necessary because the
container is behind Docker's bridge NAT) — leave them alone.

## Maintenance script

Disables nginx-ui's upstream/site health checks daily (they generate
constant background traffic to every backend, which we don't want).

```bash
sudo cp scripts/maintenance_nginx_ui.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/maintenance_nginx_ui.sh
echo "0 4 * * * root /usr/local/bin/maintenance_nginx_ui.sh >> /var/log/maintenance_nginx_ui.log 2>&1" \
    | sudo tee /etc/cron.d/nginx-ui-maintenance
```

The script `docker exec`s into the `nginx` container and runs `sqlite3`
against `/etc/nginx-ui/database.db` — no host-side `nginx-ui` needed.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The GitHub Actions workflow rebuilds and pushes `buco7854/nginx:latest`
every Sunday at 00:00 UTC, picking up upstream changes to
`uozi/nginx-ui:latest`, `crowdsecurity/openresty:latest`, and the
underlying Debian base.

## Folder layout

This image and its compose example live in `nginx/` inside the
[`buco7854/custom-docker-images`](https://github.com/buco7854/custom-docker-images)
repo. The workflow that builds it is at `.github/workflows/docker-publish.yml`
in the repo root.

```
nginx/
├── Dockerfile                # buco7854/nginx image
├── app.ini                   # default nginx-ui config baked into the image
├── docker-compose.yml        # full homelab stack
├── .env.example
├── conf/                     # bind-mounted to /etc/nginx in the container
│   ├── nginx.conf
│   ├── conf.d/{01-crowdsec.conf, 06-ratelimit.conf}
│   ├── snippets/{ratelimit.conf, security-txt.conf}
│   └── server-conf.d/.gitkeep
├── crowdsec/
│   ├── bouncer.conf
│   └── config/acquis.yaml
├── prometheus/prometheus.yml
├── grafana/provisioning/{datasources, dashboards}
├── www/well-known/security.txt
└── scripts/{write_cert.sh, maintenance_nginx_ui.sh}
```
