# buco7854/nginx — homelab reverse-proxy stack

`buco7854/nginx` is `uozi/nginx-ui:latest` with dynamic modules added to
the stock nginx it ships: a **lua module stack** (LuaJIT +
lua-nginx-module, so the CrowdSec Lua bouncer can run) and
**nginx-module-vts** that serves a custom interactive **HTML dashboard**
(no Prometheus output). Both are **compiled from source against the exact
nginx version uozi ships**. **No OpenResty** (its apt repo lags Debian by
many months) and **no Debian `libnginx-mod-*`** either — uozi ships
nginx.org *mainline*, Debian's modules target Debian's much older nginx,
and nginx's dynamic-module version check is exact (`--with-compat` does
not relax it), so a Debian module simply refuses to load.

This folder is split so it's obvious what belongs where:

| Path | What it is |
|---|---|
| `Dockerfile` | builds `ghcr.io/buco7854/nginx` |
| `image/` | **baked into the image** (VTS `status.html` + the seed `conf/`) — the build's only inputs |
| `example/` | a **ready-to-run compose stack** (NOT used by the build): nginx + CrowdSec (engine + firewall bouncer + web UI) + Certwarden |

> CrowdSec publishes **no official Docker image for the firewall
> bouncer** (host package only). `example/docker-compose.yml` uses
> `ghcr.io/buco7854/crowdsec-firewall-bouncer`, built from the
> GPG-verified packagecloud `.deb` by this repo — see
> [`../crowdsec-firewall-bouncer/`](../crowdsec-firewall-bouncer).

## Contents

- [Image](#image)
- [Setup](#setup)
  - [Prerequisites](#prerequisites)
  - [Path A — fresh install](#path-a--fresh-install)
  - [Path B — migrate an existing install](#path-b--migrate-an-existing-install)
  - [Open the UIs](#open-the-uis)
- [How it works](#how-it-works)
  - [Architecture & maintenance posture](#architecture--maintenance-posture)
  - [Config layout — seed-if-empty, never clobber](#config-layout--seed-if-empty-never-clobber)
  - [Stack overview](#stack-overview)
  - [Mount layout](#mount-layout)
  - [Service monitoring & control](#service-monitoring--control)
- [Certwarden integration](#certwarden-integration)
- [CrowdSec whitelists](#crowdsec-whitelists)
- [Maintenance script](#maintenance-script)
- [Upgrading](#upgrading)
- [Folder layout](#folder-layout)

## Image

| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/nginx:latest`  | this repo's [`Dockerfile`](./Dockerfile) + [`image/`](./image) | Weekly Sun 00:00 UTC |
| `ghcr.io/buco7854/nginx:<sha>`   | tagged on every push to `main`                                 | per-commit            |

The build only watches `Dockerfile` + `image/**`; changing the
`example/` stack never rebuilds the image.

## Setup

Everything below runs from **`nginx/example/`** (where the compose
lives). It's **one directory per service** (`nginx/`, `crowdsec/`,
`crowdsec-firewall-bouncer/`, `crowdsec-web-ui/`, `certwarden/`), each
holding that service's mounts; tracked files (the bouncer configs,
`crowdsec/conf/`) are pre-shipped, runtime dirs are auto-created on
first `up`. **Two mounts are deliberate exceptions — absolute host
paths, not relative:** `/var/www` (static web root) and
`/etc/ssl/domains` (TLS certs), because they're shared host system
locations other services on the box may also use. Two ways in:

- **[Path A — fresh install](#path-a--fresh-install)** — clean machine,
  nothing to keep; the container seeds a working nginx config for you.
- **[Path B — migrate an existing install](#path-b--migrate-an-existing-install)**
  — you already run nginx and/or CrowdSec and want to bring that config
  in.

Both finish at [Open the UIs](#open-the-uis). Do the
[Prerequisites](#prerequisites) first either way.

### Prerequisites

- Docker + Docker Compose v2.
- Ports `80`/`443` free. User-facing UIs (VTS `9113`, CrowdSec web UI,
  Certwarden `4050`/`4055`) also bind all interfaces — **gate them at
  your host firewall**; internal/sensitive ports stay loopback-only.
- Clone and fill in a `.env`:
  ```bash
  git clone https://github.com/buco7854/custom-docker-images
  cd custom-docker-images/nginx/example
  cp .env.example .env
  $EDITOR .env                # gitignored — put real secrets here
  ```
  Pick long random strings for the two bouncer keys
  (`openssl rand -hex 32`) and a long `CROWDSEC_UI_PASSWORD`. These are
  **fresh secrets even if you're migrating** — the old LAPI / bouncer
  registrations are not reused (see Path B).

Runtime dirs (`nginx/conf`, `nginx/logs`, `*/data`, …) are created by
Docker on first `up`; you don't `mkdir` anything. The two absolute
host paths — `/var/www` and `/etc/ssl/domains` — Docker also creates
if absent, but on a real host they're shared system locations: point
them at your actual web root / cert store (and `sudo mkdir -p` them
yourself if you want non-root ownership).

### Path A — fresh install

`nginx/conf` starts empty → on first start the container seeds the
default nginx + nginx-ui + CrowdSec bouncer + VTS config into it.

1. **Match the bouncer API keys.** The same value must appear in `.env`
   and in the bouncer-side config file (both ship in the repo,
   pre-wired, with `REPLACE_WITH_…` placeholders):
   ```bash
   $EDITOR nginx/crowdsec-nginx-bouncer.conf                          # API_KEY = CROWDSEC_BOUNCER_API_KEY
   $EDITOR crowdsec-firewall-bouncer/crowdsec-firewall-bouncer.yaml   # api_key = CROWDSEC_FW_BOUNCER_API_KEY
   ```
2. **Bring it up.**
   ```bash
   docker compose up -d
   ```
   The `BOUNCER_KEY_*` env vars auto-register both bouncer keys with
   LAPI on first start.
3. **Set the nginx-ui reload key.** nginx-ui auto-generates
   `nginx/nginx-ui/app.ini` (+ its DB) on first start and it persists
   in that bind mount. Add an `[auth] ApiKey` set to your `.env`'s
   `NGINX_UI_API_KEY` (Certwarden uses it to trigger reloads), then
   reload:
   ```bash
   $EDITOR nginx/nginx-ui/app.ini           # add under [auth]:  ApiKey = NGINX_UI_API_KEY
   docker compose restart nginx
   ```
4. **Register the web-UI machine account.** The CrowdSec web UI
   authenticates to LAPI with **machine credentials** (not a bouncer
   key), and the crowdsec image does not auto-register machines:
   ```bash
   docker compose exec crowdsec \
     cscli machines add "$CROWDSEC_UI_USER" --password "$CROWDSEC_UI_PASSWORD" -f /dev/null
   docker compose restart crowdsec-web-ui
   ```
   - Run with the same values as your `.env` (export them first, or
     paste literals — your shell does **not** auto-read `.env`).
   - **`-f /dev/null` is required.** `cscli machines add` registers the
     machine in the LAPI database (all you want) **and** can dump the
     new credentials into `/etc/crowdsec/local_api_credentials.yaml` —
     a bind-mounted file (`crowdsec/conf/`) that the crowdsec
     container's *own* agent uses to authenticate to its *own* LAPI.
     Letting `cscli` write it overwrites the container's identity and
     breaks the engine, persistently. `-f /dev/null` keeps the DB
     registration and discards the file dump. The web UI never needs
     that file; it logs in with the `CROWDSEC_USER`/`CROWDSEC_PASSWORD`
     env vars.

Continue to [Open the UIs](#open-the-uis).

### Path B — migrate an existing install

It's **stock nginx** and a **stock crowdsec** image, so your existing
Debian-style layout works as-is — you bind your config in and add only a
small set of integration files.

The `crowdsec/conf/` bind mount **replaces** the container's
`/etc/crowdsec` entirely — the container sees *only* what's there:

- **Standard files you DON'T ship are auto-created.** On first start
  crowdsec bootstraps anything missing into the bind dir: `config.yaml`,
  `simulation.yaml`, a default `profiles.yaml`, `patterns/`,
  notification *templates*, a generated `local_api_credentials.yaml`,
  and the `COLLECTIONS` from compose. They persist on the host.
- **Files you DO ship win** — the image only creates a default when the
  file is *absent*, never overwrites yours.
- **Your bespoke content is NOT magically migrated** — only what you
  copy into `crowdsec/conf/` exists.

Steps:

1. **Put your nginx tree in `nginx/conf`.** Drop your existing
   Debian-style config (`nginx.conf`, `conf.d/`, `sites-available/`,
   `sites-enabled/`, `snippets/`, …) into `nginx/conf`. Non-empty ⇒
   the container uses it verbatim (the image only seeds a default
   `nginx.conf` into an *empty* `nginx/conf`).
2. **Make your `nginx.conf` load the modules.** Ensure it has, at the
   **main** context, `include /etc/nginx/modules-enabled/*.conf;`
   (Debian's stock `nginx.conf` already does; nginx.org's does not) and,
   inside `http{}`, `include /etc/nginx/conf.d/*.conf;`. Do **not** add
   your own lua/vts `load_module` lines — the symlinks handle it. Strip
   any systemd-isms (`PIDFile=`, etc.) if they leaked in.
3. **Add the two `include` lines** (step 2 above) — that's the only
   manual edit. The integration's drop-ins (`modules-enabled/` symlinks
   + `conf.d/{crowdsec_nginx,realip,resolver}.conf`) are **auto-seeded
   into your `/etc/nginx` if missing** by the `ensure-integration`
   oneshot; see
   [Required for the integration to work](#required-for-the-integration-to-work).
4. **Update cert paths.** Where you had
   `ssl_certificate /certs/<domain>/...`, change to
   `ssl_certificate /etc/ssl/domains/<domain>/fullchain.pem;` (same for
   `ssl_certificate_key …/privkey.pem;`). Rate-limit / security.txt are
   optional — see [Optional extras](#optional-extras).
5. **Boot once with the shipped CrowdSec samples** so crowdsec generates
   a valid baseline (`config.yaml`, credentials, hub) into
   `crowdsec/conf/`:
   ```bash
   docker compose up -d
   ```
6. **Copy only your *authored* CrowdSec content** from the old box into
   `crowdsec/conf/`: `parsers/s02-enrich/*whitelist*.yaml`, custom
   `appsec-rules/*.yaml`, a custom `profiles.yaml`, and any custom
   `scenarios/`/`parsers/` you wrote.
   **Do NOT copy:** `config.yaml`, `*_api_credentials.yaml`, `console*`,
   `hub/`, `data/`, bouncer registrations — instance-specific, and
   regenerated for the containerised LAPI. Notification configs
   (`notifications/*.yaml`) hold tokens — keep them host-only/gitignored.
7. **Fix acquisition for the container:** log paths must match the
   container's mounts, and the AppSec listener must be
   `listen_addr: 0.0.0.0:7422` with
   `appsec_config: crowdsecurity/appsec-default` (a baremetal
   `127.0.0.1:7422` breaks — the bouncer reaches it over the compose
   network).
8. **Set the bouncer API keys — fresh secrets, *not* migrated.** The
   containerised LAPI starts with an empty DB; the `BOUNCER_KEY_*` env
   vars (from `.env`) **auto-register** a bouncer for whatever key you
   set, so just generate two new random keys in `.env`. The two bouncer
   config files **ship in the repo**, pre-wired for this stack's network
   (nginx bouncer → `http://crowdsec:8080`, firewall bouncer →
   `http://127.0.0.1:8080/`). Don't create them, and don't copy your old
   baremetal ones (wrong LAPI address). Just replace the placeholder so
   each `.env` value matches the file that reads it:
   - `CROWDSEC_BOUNCER_API_KEY` → `API_KEY` in `nginx/crowdsec-nginx-bouncer.conf`
   - `CROWDSEC_FW_BOUNCER_API_KEY` → `api_key` in `crowdsec-firewall-bouncer/crowdsec-firewall-bouncer.yaml`
   - `NGINX_UI_API_KEY` → `[auth] ApiKey` in `nginx/nginx-ui/app.ini`
9. **Restart, then register the web-UI machine.**
   ```bash
   docker compose restart crowdsec
   docker compose exec crowdsec \
     cscli machines add "$CROWDSEC_UI_USER" --password "$CROWDSEC_UI_PASSWORD" -f /dev/null
   docker compose restart crowdsec-web-ui
   ```
   `-f /dev/null` required for the same reason as
   [Path A](#path-a--fresh-install) step 4.
10. **Verify.**
    ```bash
    docker compose exec crowdsec cscli hub list
    docker compose exec crowdsec cscli metrics
    docker compose exec crowdsec cscli alerts list
    docker compose logs crowdsec        # check for parse errors
    ```

Continue to [Open the UIs](#open-the-uis).

### Open the UIs

Bound to all interfaces (gate at your firewall) — reachable on the host
and LAN:

- **nginx-ui** — `http://<host>` (port 80, via the proxy itself)
- **VTS traffic dashboard** — `http://<host>:9113/status`
- **CrowdSec web UI** — `http://<host>:9321` (or your `CROWDSEC_UI_PORT`)

---

## How it works

### Architecture & maintenance posture

`uozi/nginx-ui:latest` is the runtime base; its **stock nginx is left
exactly as-is** (no OpenResty, no binary swap, no wrapper). s6-overlay
keeps supervising nginx and nginx-ui, and because `/usr/sbin/nginx` is
the real, unmodified nginx, **nginx-ui auto-detects everything** (sbin
path, config path, pid path) — nothing to override in `app.ini`.

Modules are added as `.so` files baked at `/usr/lib/nginx/modules`
(outside `/etc/nginx`, so a host bind mount can't hide them; the
`load_module` lines live in image-owned `modules-available/` files,
symlinked from `modules-enabled/` — see config layout below):

| Module | Where it comes from | Update story |
|---|---|---|
| `ndk` + `lua` | LuaJIT (`openresty/luajit2`) + `ngx_devel_kit` + `lua-nginx-module`, compiled from **latest** upstream against the **exact** nginx uozi ships (`--with-compat --with-http_ssl_module`, same base). `lua-resty-core`/`-lrucache` vendored from the same branch so they always match. | Recompiled against the current nginx every weekly rebuild. Pin a one-off with `--build-arg <NAME>_REF=<tag>` (`LUAJIT2_REF`, `NDK_REF`, `LUA_NGINX_MODULE_REF`, `LUA_RESTY_CORE_REF`, `LUA_RESTY_LRUCACHE_REF`). |
| `vts` | Compiled from **latest** upstream against the **exact** nginx uozi ships; custom dashboard baked in via VTS's `tplToDefine.sh`. | Tracks nginx automatically. Pin with `--build-arg VTS_REF=<tag>`. |
| CrowdSec bouncer | Official `crowdsec-nginx-bouncer` `.deb` (GPG-verified); files land at the exact baremetal `apt` paths. | Pin via `--build-arg CS_NGINX_BOUNCER_VERSION`; else tracks current. |
| `lua-resty-http` / `-string` | Tiny pure-lua libs not in Debian — installed **latest** via luarocks. | Unpinned; the build-time `nginx -t` guard catches breakage. |

The principle is **fail-loud-at-build, never-silent-in-prod**: a
build-time `nginx -t` loads all three modules and runs an `init_by_lua`
that `require`s the bouncer's lua deps (forcing `resty.core`). That one
check validates the exact nginx↔module version match, `--with-compat`,
LuaJIT, the lua path, lua SSL, and `resty.core`/`http`/`string`/`cjson`.
A future upstream break fails the **weekly build**; the last good image
keeps running. No routine maintenance; pinned bits move only when you
bump an `ARG`.

### Config layout — seed-if-empty, never clobber

The image behaves like a default nginx-ui install that also ships the
CrowdSec + VTS integration, inheriting the base's `init-config`:

- **Empty `/etc/nginx` (`nginx/conf`) on first start** → seeded with
  the default nginx config, the nginx-ui `:80→:9000` proxy, **and only
  the integration bits required to function** (CrowdSec bouncer,
  real-IP, resolver, the `load_module` symlinks). The VTS module is
  *loaded* but its dashboard zone, rate-limit, and `security.txt` are
  **not** seeded — all opt-in (see [Optional extras](#optional-extras)).
- **Existing `/etc/nginx`** → **your files are never touched.** One
  scoped addition: missing integration drop-ins (`modules-enabled/`
  symlinks + the required `conf.d/` files) are (re)created (see below).

This works by enriching the base's config *template*
(`/usr/local/etc/nginx`); the base's `init-config` s6 oneshot only does
`[ -z "$(ls -A /etc/nginx)" ] && cp -rp /usr/local/etc/nginx/* /etc/nginx/`.
No custom entrypoint, no clobbering.

The one deliberate exception: a second s6 oneshot, `ensure-integration`
(ordered **after** `init-config`, **before** nginx), self-heals the
integration drop-ins — **each** `modules-enabled/` symlink and **each**
required `conf.d/` file (`crowdsec_nginx.conf`, `realip.conf`,
`resolver.conf`) — recreating only the ones that are missing, even on a
populated bring-your-own `/etc/nginx` where `init-config` does nothing.
Per-item and idempotent: anything you already have (your own, or a
correct copy) is left untouched. It never edits your `nginx.conf` — you
still add the two `include` lines yourself (that *would* be clobbering).

#### Required for the integration to work

If you **bring your own `/etc/nginx`**, almost everything self-heals.
The **only manual edit** is two stock `include` lines in your
`nginx.conf` (the image won't touch your `nginx.conf` — that *would* be
clobbering):

| You add manually | Why |
|---|---|
| `include /etc/nginx/modules-enabled/*.conf;` at the **main** context of `nginx.conf` | `load_module` is only valid in the main context. Debian's stock `nginx.conf` has this; nginx.org's doesn't — add once. |
| `include /etc/nginx/conf.d/*.conf;` inside `http{}` | Standard; pulls in everything below. |

Everything else is **auto-seeded into `/etc/nginx` if missing** by the
`ensure-integration` oneshot (per-item; a copy you already have is left
untouched, so to customise one just ship your own):

| Auto-seeded drop-in | What it is |
|---|---|
| `modules-enabled/{10-mod-http-ndk,50-mod-http-lua,90-mod-http-vhost-traffic-status}.conf` | Symlinks → the image-owned `/usr/share/nginx/modules-available/mod-http-{ndk,lua,vhost-traffic-status}.conf` (`load_module` for NDK+lua = the bouncer, and VTS). NDK `10-` before lua `50-`; VTS `90-` independent. The VTS symlink only *loads* the module — the `/status` dashboard stays inert until you opt into its zone config ([Optional extras](#optional-extras)). |
| `conf.d/crowdsec_nginx.conf` | Wires the lua bouncer into nginx (the `apt install crowdsec-nginx-bouncer` file, baked from the GPG-verified `.deb`). *Reads* the bouncer's runtime config at `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` — a bind mount, not an `/etc/nginx` file; see the note below. |
| `conf.d/realip.conf` | Without it the bouncer sees the Docker gateway IP for every request (it'd ban/allow the gateway, not real clients). |
| `conf.d/resolver.conf` | The only docker-ism. A static `proxy_pass http://name` resolves once at startup via `/etc/resolv.conf` — but the bouncer reaches LAPI/AppSec via the **lua cosocket** client, which **ignores `/etc/resolv.conf`** and resolves only via nginx's `resolver`. So `resolver 127.0.0.11;` (Docker DNS) is mandatory to look up `crowdsec`. Unneeded on baremetal where LAPI is the literal IP `127.0.0.1`. |

The seeded drop-ins live in this repo under `image/conf/` (except
`crowdsec_nginx.conf`, baked from the `.deb` — see above). `image/`
holds **only** what the Dockerfile bakes; `nginx.conf` itself is the
base image's own (not shipped here).

**Beyond `/etc/nginx` — the bouncers' own runtime config.** The table is
the `/etc/nginx` side only. The lua bouncer also reads
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` and the firewall
bouncer `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` — these
are the repo-shipped `nginx/crowdsec-nginx-bouncer.conf` /
`crowdsec-firewall-bouncer/crowdsec-firewall-bouncer.yaml`, bind-mounted by compose and
always present whether or not you bring your own `/etc/nginx`. You only
set the API key in each (Path A step 1 / Path B step 8). Without the
right key, `crowdsec_nginx.conf` loads but the bouncer can't
authenticate to LAPI.

#### Optional extras

Shipped as examples under `example/nginx/optional/`, **not** baked or
seeded — copy into your nginx config (`nginx/conf/`) only if you want
them:

- `optional/conf.d/ratelimit.conf` + `optional/snippets/ratelimit.conf`
  — connection/request rate-limit zones, opted into per-server with
  `include snippets/ratelimit.conf;` inside a `server {}`.
- `optional/snippets/security-txt.conf` — serves
  `/.well-known/security.txt`. Copy the repo's sample
  (`nginx/www/well-known/security.txt`) into the host `/var/www` and
  edit it for your contact details, opt in per-server the same way.
- `optional/conf.d/vhost-traffic-status.conf` — the VTS zone + the
  `:9113/status` traffic dashboard. The VTS module is already loaded
  (auto-seeded `90-` symlink); copy this into your `conf.d/` to
  activate `/status`. The bouncer/security work fine without it.

### Stack overview

```
                Internet
                   │ 80/443
                   ▼
┌─────────────────────────────────────────────────────┐
│  nginx (buco7854/nginx)                             │
│  stock nginx + lua module (CrowdSec bouncer,        │
│  incl. AppSec) + VTS HTML dashboard + nginx-ui      │
│  VTS dashboard → :9113/status  (HTML dashboard)     │
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

certwarden :4055 ──writes certs────▶ nginx reads /etc/ssl/domains
                 ──POST reload─────▶ nginx /api/nginx/reload
```

The reverse proxy (80/443) and user-facing UIs — VTS `:9113`, CrowdSec
web UI, Certwarden `:4050`/`:4055` — bind all interfaces; **gate them at
your host firewall**. Internal/sensitive ports stay loopback-only:
CrowdSec LAPI `:8080`, Certwarden ACME `:4060` and pprof `:4065`/`:4070`.
All services share the `proxy_net` bridge and resolve each other by
service name — except the firewall bouncer, which runs
`network_mode: host` to rewrite iptables and reaches LAPI via the
loopback-published `127.0.0.1:8080`.

The CrowdSec web UI authenticates to LAPI with **machine credentials**
(`CROWDSEC_UI_USER` / `CROWDSEC_UI_PASSWORD`), not a bouncer key, so that
machine is registered once during [Setup](#setup).

### Mount layout

Container paths are **absolute Debian-style** (stock nginx); the host
side is **relative to `nginx/example/`** (per-service) — except the two
shared host system paths, which are **absolute**:

| Container | Host | Notes |
|---|---|---|
| `/etc/nginx` | `nginx/conf` | seeded by image if empty; runtime |
| `/var/log/nginx` | `nginx/logs` | nginx writes; crowdsec reads it RO |
| `/etc/nginx-ui` | `nginx/nginx-ui` | nginx-ui sqlite DB + `app.ini`; runtime |
| `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` | `nginx/crowdsec-nginx-bouncer.conf` | **tracked** — set `API_KEY` |
| `/etc/crowdsec` | `crowdsec/conf` | **tracked** — acquis, whitelists, profiles |
| `/var/lib/crowdsec/data` | `crowdsec/data` | LAPI state DB; runtime |
| `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` | `crowdsec-firewall-bouncer/crowdsec-firewall-bouncer.yaml` | **tracked** — set `api_key` |
| `/app/data` (web UI) | `crowdsec-web-ui/data` | runtime |
| `/app/data` (certwarden) | `certwarden/data` | runtime |
| `/scripts` | `certwarden/scripts` | **tracked** (post-issuance hook) |
| `/var/www` | **`/var/www`** | **ABSOLUTE host path** (shared); repo ships a `security.txt` sample at `nginx/www/` to copy here |
| `/etc/ssl/domains` (nginx RO) & `/certs` (certwarden RW) | **`/etc/ssl/domains`** | **ABSOLUTE host path** (shared); certwarden issues, nginx reads |

One directory per service; each owns what it produces (logs → `nginx/`,
certs/scripts → `certwarden/`). **Tracked** = pre-shipped, you edit it;
everything else is runtime state Docker auto-creates on first `up`.

### Service monitoring & control

Per nginx-ui's
[service monitoring and control](https://nginxui.com/guide/config-nginx#service-monitoring-and-control):
because this is the **stock** nginx the `uozi/nginx-ui` base was built
for, every code path works with nginx-ui's auto-detected defaults — no
`app.ini` overrides. Status detection (`/var/run/nginx.pid`), `nginx -t`,
`nginx -s reload` (the Certwarden cert-reload path), and the
`start-stop-daemon` restart all behave exactly as upstream intends.

## Certwarden integration

Certwarden runs its post-issuance hook inside its own container; compose
mounts `./certwarden/scripts:/scripts:ro`, so configure Certwarden to run
`/scripts/write_cert.sh` after issuance.

The script expects these env vars (Certwarden passes them, plus
`NGINX_UI_API_KEY` from `.env`):

| Var               | Source                                |
|-------------------|---------------------------------------|
| `CERTIFICATE_PEM` | Certwarden — PEM-encoded fullchain    |
| `PRIVATE_KEY_PEM` | Certwarden — PEM-encoded private key  |
| `CERTIFICATE_NAME`| Certwarden — logical cert/domain name |
| `NGINX_UI_API_KEY`| `.env`                                |

The hook writes `fullchain.pem`/`privkey.pem` under
`/certs/<CERTIFICATE_NAME>/` in the certwarden container. That `/certs`
mount is the host's **`/etc/ssl/domains`** (absolute, shared), which
nginx reads back read-only at the same `/etc/ssl/domains`. It then
`POST`s `http://nginx/api/nginx/reload` with
the `X-API-Key` header to trigger `nginx -s reload`. (Override
`CERT_ROOT` if you remap that mount.)

## CrowdSec whitelists

Sample whitelists ship version-controlled in `crowdsec/conf/`. They're
**examples** — edit them for your environment (none contain real IPs).

| File | Stage | What it does |
|---|---|---|
| `parsers/s02-enrich/whitelists.yaml` (`my/whitelists`) | parser | Trusted IP/CIDR sources — short-circuits BOTH log scenarios AND AppSec. Active automatically. |
| `parsers/s02-enrich/nginx-ui-api-whitelist.yaml` | parser | Drops nginx-ui's own `/api/*` 403 bursts (false positive when logged out) before any scenario scores them. |
| `appsec-rules/whitelists.yaml` (`my/appsec-allow-path`) | AppSec in-band | Exempts a path from **specific** WAF rules via `on_match: allow` + `target_rules:`. Self-attaching — `acquis.yaml` stays on stock `crowdsecurity/appsec-default`. |

**Cleanest way to whitelist a path from rules:**

- From **specific** noisy rule(s) → an AppSec rule with `on_match: allow`
  + `target_rules: [<rule>]` (what `appsec-rules/whitelists.yaml` does).
  Narrowest blast radius; no appsec-config edit. **Recommended.**
- From the **entire WAF** for a path → a custom appsec-config with a
  `pre_eval`/`on_match` hook doing `SetRemediation("allow")` behind a
  path filter. One place, but disables *all* rules on that path.
- A **parser** whitelist is the wrong tool for in-band AppSec — it only
  drops the alert after the request was already 403'd in-band.

Reload after editing any of these:

```bash
docker compose restart crowdsec
```

## Maintenance script

Disables nginx-ui's upstream/site health checks daily (they generate
constant background traffic to every backend).

```bash
sudo cp nginx/maintenance_nginx_ui.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/maintenance_nginx_ui.sh
echo "0 4 * * * root /usr/local/bin/maintenance_nginx_ui.sh >> /var/log/maintenance_nginx_ui.log 2>&1" \
    | sudo tee /etc/cron.d/nginx-ui-maintenance
```

It `docker exec`s into the `nginx` container and runs `sqlite3` against
`/etc/nginx-ui/database.db` — no host-side `nginx-ui` needed.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The GitHub Actions workflow rebuilds `ghcr.io/buco7854/nginx:latest`
weekly (Sun 00:00 UTC), picking up `uozi/nginx-ui:latest` and recompiling
the lua stack + VTS against whatever nginx it ships. A breaking upstream
change fails the build (last good image keeps running) — so "upgrading"
is just `docker compose pull && docker compose up -d`. Don't use
nginx-ui's in-app self-upgrade: it's disabled here on purpose and would
be wiped on the next recreate.

### Reconciling the bind-mounted bouncer configs

The two bouncer configs are **bind-mounted from the repo**, so they
**shadow** the image/package defaults — a `pull` updates the bouncer
*code* but never your static config. Schema drift is rare and usually
benign (a missing new key keeps the old default), but a
renamed/removed/new-required key can change behaviour, and the build
guard does **not** validate bouncer config — it surfaces at runtime
(`docker compose logs crowdsec` / `crowdsec-firewall-bouncer`). The
current upstream default sits at the same path inside the freshly-pulled
image, so after a notable CrowdSec bump, diff and merge in anything new
(keep your key + the `crowdsec:8080` / `127.0.0.1:8080` wiring):

```bash
docker run --rm --entrypoint cat ghcr.io/buco7854/nginx:latest \
  /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf | diff - nginx/crowdsec-nginx-bouncer.conf

docker run --rm --entrypoint cat ghcr.io/buco7854/crowdsec-firewall-bouncer:latest \
  /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml | diff - crowdsec-firewall-bouncer/crowdsec-firewall-bouncer.yaml
```

The containerised equivalent of baremetal `apt`'s `.dpkg-dist`
reconciliation — except the reference default is always one `docker run`
away.

## Folder layout

Lives in `nginx/` inside
[`buco7854/custom-docker-images`](https://github.com/buco7854/custom-docker-images);
the build workflow is `.github/workflows/build-nginx.yml`.

```
nginx/
├── Dockerfile                 # builds ghcr.io/buco7854/nginx
├── .dockerignore              # keeps example/ out of the build context
├── README.md
├── image/                     # ── BAKED INTO THE IMAGE (only these) ──
│   ├── status.html            # custom VTS dashboard
│   └── conf/                  # seeded into /etc/nginx if empty
│       ├── modules-available/{mod-http-ndk,mod-http-lua,
│       │                      mod-http-vhost-traffic-status}.conf
│       │                        # image symlinks these into modules-enabled/
│       └── conf.d/{realip,resolver}.conf
│                                # crowdsec_nginx.conf comes from the .deb
└── example/                   # ── RUNNABLE STACK (not built) ──
    │                          #    one dir per service; (rt) = runtime,
    │                          #    auto-created on first `up`
    ├── docker-compose.yml
    ├── .env.example           # copy to .env
    ├── nginx/
    │   ├── crowdsec-nginx-bouncer.conf   # tracked — set API_KEY
    │   ├── maintenance_nginx_ui.sh       # tracked — host cron helper
    │   ├── www/well-known/security.txt   # tracked sample — copy to host /var/www
    │   ├── optional/                     # tracked — opt-in snippets:
    │   │   ├── conf.d/{ratelimit, vhost-traffic-status}.conf
    │   │   └── snippets/{ratelimit, security-txt}.conf
    │   ├── conf/                         # (rt) → /etc/nginx (seeded)
    │   ├── logs/                         # (rt) → /var/log/nginx
    │   └── nginx-ui/                     # (rt) → /etc/nginx-ui
    ├── crowdsec/
    │   ├── conf/                         # tracked — acquis, profiles,
    │   │                                 #   appsec-rules, parsers
    │   └── data/                         # (rt) → LAPI state DB
    ├── crowdsec-firewall-bouncer/
    │   └── crowdsec-firewall-bouncer.yaml   # tracked — set api_key
    ├── crowdsec-web-ui/data/             # (rt) → /app/data
    └── certwarden/
        ├── scripts/write_cert.sh         # tracked — issuance hook
        └── data/                         # (rt) → /app/data

ABSOLUTE host paths (not under example/, shared with the host):
  /var/www           static web root  (sample: nginx/www/ — copy here)
  /etc/ssl/domains   TLS certs        (certwarden writes, nginx reads RO)
```
