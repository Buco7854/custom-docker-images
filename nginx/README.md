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
│  OpenResty + CrowdSec lua bouncer (incl. AppSec)    │
│  + nginx-ui                                         │
└──┬───────────────┬──────────────┬───────────────────┘
   │ access/error  │ AppSec WAF   │ /metrics :9113
   ▼               ▼              ▼
┌─────────────────────────┐  ┌────────────┐
│ crowdsec  LAPI  :8080   │  │ prometheus │──── grafana :3001
│           AppSec :7422  │  └────────────┘
└──┬──────────────┬───────┘
   │ decisions    │ alerts
   ▼              ▼
┌─────────────┐  ┌──────────────┐
│ firewall    │  │ crowdsec-ui  │
│ bouncer     │  │ :3000        │
│ (iptables)  │  └──────────────┘
└─────────────┘

certwarden :4055 ──writes certs──▶ /etc/ssl/domains/
                 ──POST reload──▶  nginx /api/nginx/reload
```

Everything except 80/443 binds to `127.0.0.1` only — nothing on the LAN
can talk to LAPI, Grafana, the CrowdSec UI, Prometheus, or Certwarden's
admin port. All services share the `proxy_net` bridge network and
resolve each other by service name — except the firewall bouncer, which
runs with `network_mode: host` so it can rewrite iptables, and reaches
LAPI via the loopback-published `127.0.0.1:8080`.

### Host paths

The nginx container uses **absolute Debian-style paths**, bind-mounted
from the host:

| Container          | Host                | Owner                              |
|--------------------|---------------------|------------------------------------|
| `/etc/nginx`       | `/etc/nginx`        | you — drop your config here        |
| `/var/log/nginx`   | `/var/log/nginx`    | nginx writes, crowdsec reads (RO)  |
| `/etc/ssl/domains` | `/etc/ssl/domains`  | certwarden writes, nginx reads (RO)|

Everything else (nginx-ui state, www files, crowdsec data, prometheus
volume, etc.) stays in relative dirs next to `docker-compose.yml`.

## First-time setup

1. **Clone and configure.**
   ```bash
   git clone https://github.com/buco7854/custom-docker-images
   cd custom-docker-images/nginx
   cp .env.example .env
   $EDITOR .env                # fills in CROWDSEC_*_API_KEY, NGINX_UI_API_KEY, etc.
   ```
2. **Seed the host directories from the repo.**
   ```bash
   sudo cp -rn conf/. /etc/nginx/
   sudo mkdir -p /var/log/nginx /etc/ssl/domains
   ```
   Drop your existing Debian-style tree (`sites-available/`,
   `sites-enabled/`, plus any custom files) into `/etc/nginx/` —
   structure is preserved 1:1.
3. **Match the API keys in the bouncer config files.**
   ```bash
   $EDITOR crowdsec/bouncer.conf            # API_KEY = CROWDSEC_BOUNCER_API_KEY
   $EDITOR crowdsec/firewall-bouncer.yaml   # api_key = CROWDSEC_FW_BOUNCER_API_KEY
   $EDITOR nginx-ui/app.ini                 # [auth] ApiKey = NGINX_UI_API_KEY (after first start)
   ```
4. **Bring it up.**
   ```bash
   docker compose up -d
   ```
   The `BOUNCER_KEY_*` env vars on the CrowdSec service auto-register
   all three bouncer keys on first start.
5. **Open the UIs.**
   - nginx-ui — http://localhost (served on port 80 via the proxy itself)
   - Grafana — http://localhost:3001 (import dashboard ID `10442`)
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
`/etc/ssl/domains/<CERTIFICATE_NAME>/` (which is `/etc/ssl/domains/` on
the host, bind-mounted into nginx read-only) and then `POST`s
`http://nginx/api/nginx/reload` with the `X-API-Key` header to trigger
`nginx -s reload`.

## CrowdSec whitelists

Two whitelist files ship in the seed config:

- **`crowdsec/config/parsers/s02-enrich/whitelists.yaml`** — runs in the
  parser stage, so it short-circuits BOTH log-based scenarios AND
  AppSec events. Use it for trusted IP/CIDR sources.
- **`crowdsec/config/appsec-rules/whitelists.yaml`** — AppSec-specific
  custom rules (e.g. skip the WAF for `/healthz`). Add `my/...` rules
  here and reference them from an appsec-config override if you need
  the rule list to extend the default one.

Reload after editing either file:

```bash
docker compose restart crowdsec
```

## Nginx config migration

The Debian layout is preserved — `conf.d/`, `sites-available/`,
`sites-enabled/`, `server-conf.d/`, and `snippets/` all work exactly as
they did on a bare-metal Debian host. To migrate:

- **Drop your existing tree into `/etc/nginx/`.** Don't merge —
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
├── nginx-wrapper.sh          # /usr/sbin/nginx wrapper that adds -c /etc/nginx/nginx.conf
├── docker-compose.yml        # full homelab stack
├── .env.example
├── conf/                     # seed config — copy to /etc/nginx/ on the host
│   ├── nginx.conf
│   ├── conf.d/{01-crowdsec.conf, 06-ratelimit.conf}
│   ├── snippets/{ratelimit.conf, security-txt.conf}
│   └── server-conf.d/.gitkeep
├── crowdsec/
│   ├── bouncer.conf                       # nginx Lua bouncer (mounted into nginx)
│   ├── firewall-bouncer.yaml              # firewall bouncer (mounted into firewall-bouncer)
│   └── config/                            # mounted into the crowdsec container
│       ├── acquis.yaml                    # nginx logs + AppSec listener
│       ├── parsers/s02-enrich/whitelists.yaml
│       └── appsec-rules/whitelists.yaml
├── prometheus/prometheus.yml
├── grafana/provisioning/{datasources, dashboards}
├── www/well-known/security.txt
└── scripts/{write_cert.sh, maintenance_nginx_ui.sh}
```
