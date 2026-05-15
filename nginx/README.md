# buco7854/nginx — homelab reverse-proxy stack

`buco7854/nginx` is `uozi/nginx-ui:latest` with two dynamic modules added
to the stock nginx it ships: Debian's **lua module** (so the CrowdSec Lua
bouncer can run) and a compiled **nginx-module-vts** that serves a custom
interactive **HTML dashboard** (no Prometheus output). **No OpenResty** —
its apt repo lags Debian releases by many months, which is unworkable.
This repo also contains a ready-to-run `docker-compose.yml` wiring nginx
with CrowdSec (engine + firewall bouncer + web UI) and Certwarden. No
Prometheus/Grafana — nginx traffic is the VTS HTML dashboard and
CrowdSec has its own web UI.

## Image

| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/nginx:latest`  | this repo's [`Dockerfile`](./Dockerfile) | Weekly Sun 00:00 UTC |
| `ghcr.io/buco7854/nginx:<sha>`   | tagged on every push to `main`           | per-commit            |

### Architecture & maintenance posture

`uozi/nginx-ui:latest` is the runtime base; its **stock nginx is left
exactly as-is** (no OpenResty, no binary swap, no wrapper). s6-overlay
keeps supervising nginx and nginx-ui, and because `/usr/sbin/nginx` is
the real, unmodified nginx, **nginx-ui auto-detects everything** (sbin
path, config path, pid path) and its default reload/test/restart
commands all just work — there is nothing to override in `app.ini`.

Two modules are added as `.so` files baked at `/usr/lib/nginx/modules`
(outside `/etc/nginx`, so a host bind mount can't hide them; the
`load_module` lines live in the `modules-enabled/` drop-in — see
config layout below):

| Module | Where it comes from | Update story |
|---|---|---|
| `ndk` + `lua` | Debian `libnginx-mod-http-ndk` / `libnginx-mod-http-lua`, fetched from the **same base image** so the release always matches the running nginx. Built `--with-compat` (the ABI contract that lets the module load into nginx.org's nginx). | **Auto-patched by Debian** on every weekly rebuild. |
| `vts` | Compiled from **latest** upstream (default branch) against the **exact** nginx version uozi ships (detected from `nginx -v`), `--with-compat`, on the same base. The custom dashboard is baked in via VTS's `tplToDefine.sh`. | Tracks nginx automatically every rebuild; VTS upstream fixes nginx-compat on that branch first. Pin a one-off with `--build-arg VTS_REF=<tag>`. |
| CrowdSec bouncer | Official `crowdsec-nginx-bouncer` `.deb` (GPG-verified); files land at the exact baremetal `apt` paths. | Pinnable via `--build-arg CS_NGINX_BOUNCER_VERSION`; otherwise tracks the repo's current. |
| `lua-resty-http` / `-string` | Tiny pure-lua libs the bouncer needs, not in Debian — installed **latest** via luarocks (same as you'd do by hand on baremetal plain nginx). | Unpinned; the build-time `nginx -t` guard catches breakage. |

The design principle is **fail-loud-at-build, never-silent-in-prod**: a
build-time `nginx -t` actually loads all three modules and `require`s the
lua deps. If a future upstream ever breaks `--with-compat` or a path, the
**weekly build fails** and the last good image keeps running — it never
ships broken. There is no routine maintenance: Debian patches nginx/lua,
VTS recompiles itself against the current nginx, and the pinned bits only
move when you choose to bump an `ARG`.

### Config layout — seed-if-empty, never clobber

The image behaves like a **default nginx-ui install that also ships the
CrowdSec + VTS integration**. It inherits the base image's `init-config`
behaviour exactly:

- **Empty `/etc/nginx` on first start** → seeded with the default nginx
  config, the nginx-ui `:80→:9000` proxy, **and only the integration
  bits that are required to function** (CrowdSec bouncer, VTS dashboard,
  real-IP, resolver, the `load_module` lines). User-policy config
  (rate-limiting, `security.txt`) is **not** seeded — it's your choice
  (see [Optional extras](#optional-extras)).
- **Existing `/etc/nginx`** (your bind-mounted config) → **nothing is
  touched.** Your config is used verbatim.

This works because we enrich the base's config *template*
(`/usr/local/etc/nginx`); the base's `init-config` s6 oneshot runs
before nginx and only does
`[ -z "$(ls -A /etc/nginx)" ] && cp -rp /usr/local/etc/nginx/* /etc/nginx/`.
No custom entrypoint, no clobbering.

#### Required for the integration to work

If you **import your own `/etc/nginx`** (so nothing is seeded), these are
the *only* things you must add for the CrowdSec bouncer + VTS + nginx-ui
to function. Names match a normal Debian baremetal install — nothing
`buco`-branded:

| File | Why it's required |
|---|---|
| `modules-enabled/10-mod-http-ndk.conf`, `50-mod-http-lua.conf`, `70-mod-http-vhost-traffic-status.conf` | `load_module` for NDK+lua (the bouncer) and VTS (the dashboard). One line each, Debian's `NN-mod-http-<name>.conf` convention. The `.so` files live in the image at `/usr/lib/nginx/modules` (outside `/etc/nginx`). |
| `include /etc/nginx/modules-enabled/*.conf;` at the **main** context of your `nginx.conf` | `load_module` is only valid in the main context, never `http{}`. Debian's stock `nginx.conf` already has this line; nginx.org's does not — add it once. |
| `include /etc/nginx/conf.d/*.conf;` inside `http{}` | Standard; pulls in everything below. |
| `conf.d/crowdsec_nginx.conf` | The CrowdSec bouncer itself. Ships in the bouncer package, **not this repo** — grab it from a seeded run: `docker cp nginx:/etc/nginx/conf.d/crowdsec_nginx.conf .` (it's byte-for-byte the file `apt install crowdsec-nginx-bouncer` installs). |
| `conf.d/realip.conf` | Without it the bouncer sees the Docker gateway IP for every request and is effectively useless (it'd ban/allow the gateway, not real clients). |
| `conf.d/resolver.conf` | The only docker-ism: lets the bouncer's lua client resolve the `crowdsec` service name. Unneeded on real baremetal where LAPI is `127.0.0.1`. |
| `conf.d/vts.conf` | VTS zone + the `:9113/status` HTML dashboard. Drop this (and `70-mod-http-vhost-traffic-status.conf`) if you don't want the traffic dashboard — the bouncer still works without it. |

Everything is in this repo under `conf/` (except `crowdsec_nginx.conf`,
which is a package file — see above). The repo's `conf/nginx.conf` is
just a plain reference skeleton; you don't need it if you bring your own.

#### Optional extras

Shipped as examples under `conf/optional/`, **not** seeded — copy into
your `/etc/nginx/` only if you want them:

- `optional/conf.d/ratelimit.conf` + `optional/snippets/ratelimit.conf`
  — connection/request rate-limit zones, opted into per-server with
  `include snippets/ratelimit.conf;` inside a `server {}` block.
- `optional/snippets/security-txt.conf` — serves
  `/.well-known/security.txt` (edit `www/well-known/security.txt` for
  your contact details), opted in per-server the same way.

### Service monitoring & control

Per nginx-ui's
[service monitoring and control](https://nginxui.com/guide/config-nginx#service-monitoring-and-control):
because this is the **stock** nginx the `uozi/nginx-ui` base was built
for, every code path works with nginx-ui's auto-detected defaults — no
`app.ini` overrides, no wrapper, no `PIDPath`/`RestartCmd` juggling.
Status detection (`/var/run/nginx.pid`), `nginx -t`, `nginx -s reload`
(the Certwarden cert-reload path), and the `start-stop-daemon` restart
all behave exactly as upstream intends, since `/usr/sbin/nginx` is the
real binary.

## Stack overview

```
                Internet
                   │ 80/443
                   ▼
┌─────────────────────────────────────────────────────┐
│  nginx (buco7854/nginx)                             │
│  stock nginx + lua module (CrowdSec bouncer,        │
│  incl. AppSec) + VTS HTML dashboard + nginx-ui      │
│  VTS dashboard → :9113/status  (HTML, loopback)     │
└──┬───────────────┬──────────────────────────────────┘
   │ access/error  │ AppSec WAF
   ▼               ▼
┌─────────────────────────┐
│ crowdsec  LAPI  :8080   │
│           AppSec :7422  │
└──┬──────────────┬───────┘
   │ decisions    │ alerts
   ▼              ▼
┌─────────────┐  ┌────────────────┐
│ firewall    │  │ crowdsec-web-ui│
│ bouncer     │  │ :9321 (machine │
│ (iptables)  │  │  creds → LAPI) │
└─────────────┘  └────────────────┘

certwarden :4055 ──writes /certs/──▶ host /etc/ssl/domains/
                 ──POST reload────▶  nginx /api/nginx/reload
```

Everything except 80/443 binds to `127.0.0.1` only — nothing on the LAN
can talk to LAPI, the CrowdSec UI, the VTS dashboard, or Certwarden's
ports. All services share the `proxy_net` bridge network and resolve
each other by service name — except the firewall bouncer, which runs
with `network_mode: host` so it can rewrite iptables, and reaches LAPI
via the loopback-published `127.0.0.1:8080`.

The CrowdSec web UI authenticates to LAPI with **machine credentials**
(`CROWDSEC_UI_USER` / `CROWDSEC_UI_PASSWORD`), not a bouncer API key, so
that machine has to be registered once (see setup step 5).

### Host paths

The nginx container uses **absolute Debian-style paths**, bind-mounted
from the host:

| Container          | Host                | Owner                              |
|--------------------|---------------------|------------------------------------|
| `/etc/nginx`       | `/etc/nginx`        | you — drop your config here        |
| `/var/log/nginx`   | `/var/log/nginx`    | nginx writes, crowdsec reads (RO)  |
| `/etc/ssl/domains` | `/etc/ssl/domains`  | certwarden writes (via its `/certs` mount), nginx reads (RO)|

Everything else (nginx-ui state, www files, crowdsec data, web-ui data,
certwarden data) stays in relative bind-mount dirs next to
`docker-compose.yml` — all gitignored.

## First-time setup

1. **Clone and configure.**
   ```bash
   git clone https://github.com/buco7854/custom-docker-images
   cd custom-docker-images/nginx
   cp .env.example .env
   $EDITOR .env                # .env is gitignored — put real secrets here
   ```
2. **Create the host dirs.**
   ```bash
   sudo mkdir -p /etc/nginx /var/log/nginx /etc/ssl/domains
   ```
   Leave `/etc/nginx` **empty** to let the container seed it (default
   nginx + nginx-ui + CrowdSec + VTS) on first start. Or drop your
   existing Debian-style tree (`nginx.conf`, `sites-enabled/`, …) into
   `/etc/nginx` — if it's non-empty the container won't touch it; then
   add the required integration files into it (see
   [Required for the integration to work](#required-for-the-integration-to-work)).
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
   both bouncer keys on first start.
5. **Register the web-UI machine account.** The CrowdSec web UI uses
   machine credentials (not a bouncer key), and the crowdsec image does
   not auto-register machines:
   ```bash
   docker compose exec crowdsec \
     cscli machines add "$CROWDSEC_UI_USER" --password "$CROWDSEC_UI_PASSWORD"
   docker compose restart crowdsec-web-ui
   ```
   (Run with the same values as your `.env`, or export them first.)
6. **Open the UIs.**
   - nginx-ui — http://localhost (served on port 80 via the proxy itself)
   - VTS traffic dashboard — http://localhost:9113/status (the custom
     HTML dashboard baked into the module)
   - CrowdSec web UI — http://localhost:9321

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
`/certs/<CERTIFICATE_NAME>/` inside the certwarden container. That
`/certs` mount is the host's `/etc/ssl/domains`, which nginx reads
back read-only at `/etc/ssl/domains`. It then `POST`s
`http://nginx/api/nginx/reload` with the `X-API-Key` header to trigger
`nginx -s reload`. (Override `CERT_ROOT` if you remap that mount.)

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

It's stock nginx, so your existing Debian layout (`conf.d/`,
`sites-available/`, `sites-enabled/`, `snippets/`, `server-conf.d/`, …)
works exactly as it did on bare metal — the image adds nothing of its
own to those, only the required files below. To migrate:

- **Keep your own `nginx.conf`.** You don't need this repo's seed one.
  Just ensure it has `include /etc/nginx/modules-enabled/*.conf;` at the
  **main** context (Debian's stock `nginx.conf` already does) and
  `include /etc/nginx/conf.d/*.conf;` inside `http{}` (standard).
- **Add the required files** listed in
  [Required for the integration to work](#required-for-the-integration-to-work)
  — that's the entire integration, no edits to your `nginx.conf` body
  beyond the two stock `include` lines.
- **Don't add your own lua/vts `load_module`** — the drop-ins handle it.
- **Strip systemd-isms** if any leaked in (`PIDFile=`, etc.).
- **Update cert paths.** Where you had `ssl_certificate /certs/<domain>/...`,
  change to `ssl_certificate /etc/ssl/domains/<domain>/fullchain.pem;`
  (same for `ssl_certificate_key /etc/ssl/domains/<domain>/privkey.pem;`).
- **Rate-limit / security.txt** are optional — see
  [Optional extras](#optional-extras) if you want them.

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

The GitHub Actions workflow rebuilds and pushes `ghcr.io/buco7854/nginx:latest`
every Sunday at 00:00 UTC, picking up `uozi/nginx-ui:latest`, Debian
security patches for nginx and the lua module, and recompiling VTS
against whatever nginx version ships. If an upstream change ever breaks
compatibility the build fails (the last good image keeps running) — so
"upgrading" is just `docker compose pull && docker compose up -d`.

## Folder layout

This image and its compose example live in `nginx/` inside the
[`buco7854/custom-docker-images`](https://github.com/buco7854/custom-docker-images)
repo. The workflow that builds it is at `.github/workflows/build-nginx.yml`
in the repo root.

```
nginx/
├── Dockerfile                # buco7854/nginx image (stock nginx + lua + vts)
├── status.html               # custom VTS dashboard, baked into the module
├── app.ini                   # minimal nginx-ui config baked into the image
├── docker-compose.yml        # full homelab stack
├── .env.example              # template — copy to .env (gitignored)
├── conf/                     # REQUIRED bits — seeded into /etc/nginx if empty
│   ├── nginx.conf            # plain skeleton (only for a from-scratch user)
│   ├── mime.types
│   ├── modules-enabled/{10-mod-http-ndk, 50-mod-http-lua,
│   │                    70-mod-http-vhost-traffic-status}.conf
│   ├── conf.d/{realip, resolver, vts}.conf
│   │                          # crowdsec_nginx.conf comes from the .deb
│   └── optional/             # NOT seeded — opt-in examples (see README)
│       ├── conf.d/ratelimit.conf
│       └── snippets/{ratelimit.conf, security-txt.conf}
├── crowdsec/
│   ├── bouncer.conf                       # nginx Lua bouncer (mounted into nginx)
│   ├── firewall-bouncer.yaml              # firewall bouncer (mounted into firewall-bouncer)
│   └── config/                            # mounted into the crowdsec container
│       ├── acquis.yaml                    # nginx logs + AppSec listener
│       ├── parsers/s02-enrich/whitelists.yaml
│       └── appsec-rules/whitelists.yaml
├── www/well-known/security.txt
└── scripts/{write_cert.sh, maintenance_nginx_ui.sh}
```
