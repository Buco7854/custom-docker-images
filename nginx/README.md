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

This repo also contains a ready-to-run `docker-compose.yml` wiring nginx
with CrowdSec (engine + firewall bouncer + web UI) and Certwarden. No
Prometheus/Grafana — nginx traffic is the VTS HTML dashboard and
CrowdSec has its own web UI.

> CrowdSec publishes **no official Docker image for the firewall
> bouncer** (it ships only as a host package). The compose file uses
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
  - [Host paths](#host-paths)
  - [Service monitoring & control](#service-monitoring--control)
- [Certwarden integration](#certwarden-integration)
- [CrowdSec whitelists](#crowdsec-whitelists)
- [Maintenance script](#maintenance-script)
- [Upgrading](#upgrading)
- [Folder layout](#folder-layout)

## Image

| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/nginx:latest`  | this repo's [`Dockerfile`](./Dockerfile) | Weekly Sun 00:00 UTC |
| `ghcr.io/buco7854/nginx:<sha>`   | tagged on every push to `main`           | per-commit            |

## Setup

Two ways in:

- **[Path A — fresh install](#path-a--fresh-install)** — a clean machine,
  nothing to keep. The container seeds a working config for you.
- **[Path B — migrate an existing install](#path-b--migrate-an-existing-install)**
  — you already run nginx and/or CrowdSec (bare metal or another compose)
  and want to bring that config in.

Both finish at [Open the UIs](#open-the-uis). Do the
[Prerequisites](#prerequisites) first either way.

### Prerequisites

- Docker + Docker Compose v2.
- Ports `80`/`443` free on the host. User-facing UIs (VTS `9113`,
  CrowdSec web UI, Certwarden `4050`/`4055`) also bind to all
  interfaces — **gate them at your host firewall**; internal/sensitive
  ports stay loopback-only.
- Create the host dirs (the nginx container uses absolute Debian-style
  paths — see [Host paths](#host-paths)):
  ```bash
  sudo mkdir -p /etc/nginx /var/log/nginx /etc/ssl/domains /var/www
  ```
- Clone the repo and fill in a `.env`:
  ```bash
  git clone https://github.com/buco7854/custom-docker-images
  cd custom-docker-images/nginx
  cp .env.example .env
  $EDITOR .env                # .env is gitignored — put real secrets here
  ```
  Pick long random strings for the two bouncer keys
  (`openssl rand -hex 32`) and a long `CROWDSEC_UI_PASSWORD`. These are
  **fresh secrets even if you're migrating** — the old LAPI / bouncer
  registrations are not reused (see Path B step 8).

### Path A — fresh install

Leave `/etc/nginx` **empty** — on first start the container seeds the
default nginx + nginx-ui + CrowdSec bouncer + VTS config into it.

1. **Match the bouncer API keys.** The same value must appear on both
   sides — the `.env` var and the bouncer-side config file:
   ```bash
   $EDITOR crowdsec_nginx-bouncer.conf            # API_KEY = CROWDSEC_BOUNCER_API_KEY
   $EDITOR crowdsec_firewall-bouncer.yaml   # api_key = CROWDSEC_FW_BOUNCER_API_KEY
   ```
2. **Bring it up.**
   ```bash
   docker compose up -d
   ```
   The `BOUNCER_KEY_*` env vars on the CrowdSec service auto-register
   both bouncer keys on first start.
3. **Set the nginx-ui reload key.** `nginx-ui/app.ini` exists after the
   first start — set its `[auth] ApiKey` to your `.env`'s
   `NGINX_UI_API_KEY` (Certwarden uses it to trigger reloads), then
   reload it:
   ```bash
   $EDITOR nginx-ui/app.ini                 # [auth] ApiKey = NGINX_UI_API_KEY
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
     paste literals).
   - **`-f /dev/null` is required.** `cscli machines add` does two
     things: it registers the machine in the LAPI database (all you
     want here) **and** can dump the new credentials into
     `/etc/crowdsec/local_api_credentials.yaml`. That file is
     bind-mounted (`crowdsec_config/`) and is what the crowdsec
     container's *own* agent uses to authenticate to its *own* LAPI.
     Letting `cscli` write it overwrites the container's identity and
     breaks the engine — persistently, because it's a bind mount.
     `-f /dev/null` keeps the DB registration and sends the file dump
     to the void. The web UI never needs that file; it logs in with the
     `CROWDSEC_USER`/`CROWDSEC_PASSWORD` env vars.

Continue to [Open the UIs](#open-the-uis).

### Path B — migrate an existing install

It's **stock nginx** and a **stock crowdsec** image, so your existing
Debian-style layout works as-is — you bind your config in and add only
the small set of integration files.

The `crowdsec_config/` bind mount **replaces** the container's
`/etc/crowdsec` entirely — the container sees *only* what's in that host
dir, nothing from the image's defaults. So "what about files that aren't
in the mount?":

- **Standard files you DON'T ship are auto-created.** On first start the
  crowdsec image bootstraps anything missing into the bind dir:
  `config.yaml`, `simulation.yaml`, a default `profiles.yaml`, the
  `patterns/`, notification *templates*, generated
  `local_api_credentials.yaml`, and the `COLLECTIONS` from
  `docker-compose.yml`. They then persist on the host.
- **Files you DO ship win** — the image only creates a default when the
  file is *absent*, never overwrites yours (that's why shipping
  `profiles.yaml` overrides the default).
- **Your bespoke content is NOT magically migrated** — only what you
  copy into `crowdsec_config/` exists.

Steps:

1. **Put your nginx tree in `/etc/nginx`.** Drop your existing
   Debian-style config (`nginx.conf`, `conf.d/`, `sites-available/`,
   `sites-enabled/`, `snippets/`, `server-conf.d/`, …) into the host
   `/etc/nginx`. If it's non-empty the container won't touch it — it's
   used verbatim. You don't need this repo's seed `nginx.conf`.
2. **Make your `nginx.conf` load the modules.** Ensure it has, at the
   **main** context, `include /etc/nginx/modules-enabled/*.conf;`
   (Debian's stock `nginx.conf` already does; nginx.org's does not — add
   it once) and, inside `http{}`, `include /etc/nginx/conf.d/*.conf;`
   (standard). Do **not** add your own lua/vts `load_module` lines — the
   drop-ins handle it. Strip any systemd-isms (`PIDFile=`, etc.) if they
   leaked in.
3. **Add the required integration files** listed in
   [Required for the integration to work](#required-for-the-integration-to-work)
   — that's the entire integration, no edits to your `nginx.conf` body
   beyond the two stock `include` lines. Real-IP directives are already
   in the shipped config (necessary behind Docker's bridge NAT) — leave
   them alone.
4. **Update cert paths.** Where you had
   `ssl_certificate /certs/<domain>/...`, change to
   `ssl_certificate /etc/ssl/domains/<domain>/fullchain.pem;` (same for
   `ssl_certificate_key /etc/ssl/domains/<domain>/privkey.pem;`).
   Rate-limit / security.txt are optional — see
   [Optional extras](#optional-extras) if you want them.
5. **Boot once with the shipped CrowdSec samples** so the image
   generates a valid baseline (`config.yaml`, credentials, hub) into
   `crowdsec_config/`:
   ```bash
   docker compose up -d
   ```
6. **Copy only your *authored* CrowdSec content** from the old box into
   `crowdsec_config/`: `parsers/s02-enrich/*whitelist*.yaml`, custom
   `appsec-rules/*.yaml`, a custom `profiles.yaml`, and any custom
   `scenarios/`/`parsers/` you wrote. (You don't need a custom
   `appsec-configs/` unless you actually edited one — stock
   `crowdsecurity/appsec-default` + `target_rules` is enough.)
   **Do NOT copy:** `config.yaml`, `*_api_credentials.yaml`, `console*`,
   `hub/`, `data/`, bouncer registrations — these are instance-specific
   and regenerated for the containerised LAPI. Notification configs
   (`notifications/*.yaml`) hold tokens — keep them host-only or
   gitignored, never commit; rotate any token that has been exposed.
7. **Fix acquisition for the container:** log paths must match the
   container's mounts, and the AppSec listener must be
   `listen_addr: 0.0.0.0:7422` with
   `appsec_config: crowdsecurity/appsec-default` (your baremetal
   `127.0.0.1:7422` would break — the bouncer reaches it over the
   compose network).
8. **Set the bouncer API keys — fresh secrets, *not* migrated.** Your
   old box's LAPI database and bouncer registrations are **not** carried
   over (step 6): the containerised LAPI starts with an empty DB, and on
   first start the `BOUNCER_KEY_nginx` / `BOUNCER_KEY_firewall` env vars
   (fed from `.env`) **auto-register** a bouncer for whatever key string
   you set. So just generate two new random keys
   (`openssl rand -hex 32`) in `.env`, exactly as for a fresh install —
   nothing is checked against the old install.

   The two bouncer config files themselves **ship in the repo**
   (`crowdsec_nginx-bouncer.conf`, `crowdsec_firewall-bouncer.yaml`) — `git
   clone` already gave you them, bind-mounted into the containers and
   pre-wired for this stack's network with `REPLACE_WITH_…` placeholder
   keys. You do **not** create or generate them, and you should **not**
   copy your old baremetal ones: the repo files already point the nginx
   bouncer at `http://crowdsec:8080` (the compose service name) and the
   firewall bouncer at `http://127.0.0.1:8080/` (it's host-networked),
   whereas a baremetal config would have the wrong LAPI address. Just
   replace the placeholder so each `.env` value matches the file that
   reads it:
   - `CROWDSEC_BOUNCER_API_KEY` → `API_KEY` in `crowdsec_nginx-bouncer.conf`
   - `CROWDSEC_FW_BOUNCER_API_KEY` → `api_key` in `crowdsec_firewall-bouncer.yaml`
   - `NGINX_UI_API_KEY` → `[auth] ApiKey` in `nginx-ui/app.ini`

   (Pasting your *old* key strings instead also works — they're just
   shared secrets — but there's no reconnection benefit since the old
   LAPI isn't kept, so fresh is cleaner.)
9. **Restart, then register the web-UI machine.**
   ```bash
   docker compose restart crowdsec
   docker compose exec crowdsec \
     cscli machines add "$CROWDSEC_UI_USER" --password "$CROWDSEC_UI_PASSWORD" -f /dev/null
   docker compose restart crowdsec-web-ui
   ```
   `-f /dev/null` is required for the same reason as in
   [Path A](#path-a--fresh-install) step 4 — it stops `cscli` from
   clobbering the bind-mounted `local_api_credentials.yaml` the engine
   authenticates with.
10. **Verify.**
    ```bash
    docker compose exec crowdsec cscli hub list
    docker compose exec crowdsec cscli metrics
    docker compose exec crowdsec cscli alerts list
    docker compose logs crowdsec        # check for parse errors
    ```

Continue to [Open the UIs](#open-the-uis).

### Open the UIs

- **nginx-ui** — http://localhost (served on port 80 via the proxy itself)
- **VTS traffic dashboard** — http://localhost:9113/status (the custom
  HTML dashboard baked into the module)
- **CrowdSec web UI** — http://localhost:9321

---

## How it works

### Architecture & maintenance posture

`uozi/nginx-ui:latest` is the runtime base; its **stock nginx is left
exactly as-is** (no OpenResty, no binary swap, no wrapper). s6-overlay
keeps supervising nginx and nginx-ui, and because `/usr/sbin/nginx` is
the real, unmodified nginx, **nginx-ui auto-detects everything** (sbin
path, config path, pid path) and its default reload/test/restart
commands all just work — there is nothing to override in `app.ini`.

Two modules are added as `.so` files baked at `/usr/lib/nginx/modules`
(outside `/etc/nginx`, so a host bind mount can't hide them; the
`load_module` lines live in the image-owned `modules-available/` files,
symlinked from `modules-enabled/` — see config layout below):

| Module | Where it comes from | Update story |
|---|---|---|
| `ndk` + `lua` | LuaJIT (`openresty/luajit2`) + `ngx_devel_kit` + `lua-nginx-module`, compiled from **latest** upstream (default branch) against the **exact** nginx version uozi ships (detected from `nginx -v`), `--with-compat`, on the same base. `lua-resty-core`/`-lrucache` (mandatory for modern lua-nginx-module) are vendored from the same default branch so they always match. | Recompiled against the current nginx every weekly rebuild; tracks nginx automatically. The set moves together on upstream's default branches. Pin a one-off with the matching `--build-arg <NAME>_REF=<tag>` (`LUAJIT2_REF`, `NDK_REF`, `LUA_NGINX_MODULE_REF`, `LUA_RESTY_CORE_REF`, `LUA_RESTY_LRUCACHE_REF`). |
| `vts` | Compiled from **latest** upstream (default branch) against the **exact** nginx version uozi ships (detected from `nginx -v`), `--with-compat`, on the same base. The custom dashboard is baked in via VTS's `tplToDefine.sh`. | Tracks nginx automatically every rebuild; VTS upstream fixes nginx-compat on that branch first. Pin a one-off with `--build-arg VTS_REF=<tag>`. |
| CrowdSec bouncer | Official `crowdsec-nginx-bouncer` `.deb` (GPG-verified); files land at the exact baremetal `apt` paths. | Pinnable via `--build-arg CS_NGINX_BOUNCER_VERSION`; otherwise tracks the repo's current. |
| `lua-resty-http` / `-string` | Tiny pure-lua libs the bouncer needs, not in Debian — installed **latest** via luarocks (same as you'd do by hand on baremetal plain nginx). | Unpinned; the build-time `nginx -t` guard catches breakage. |

The design principle is **fail-loud-at-build, never-silent-in-prod**: a
build-time `nginx -t` loads all three modules and runs an `init_by_lua`
that `require`s the bouncer's lua deps. `init_by_lua` forces
lua-nginx-module to load `resty.core` (mandatory — it aborts if missing),
so that single check validates the whole stack: the exact
nginx↔module version match, `--with-compat`, LuaJIT, the lua path, and
`resty.core`/`http`/`string`/`cjson` all resolving. If a future upstream
ever breaks any of that, the **weekly build fails** and the last good
image keeps running — it never ships broken. There is no routine
maintenance: the lua stack and VTS recompile themselves against the
current nginx every rebuild, and the pinned bits only move when you
choose to bump an `ARG`.

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
- **Existing `/etc/nginx`** (your bind-mounted config) → **your files
  are never touched.** The one scoped addition: if `modules-enabled/`
  is empty or absent, the integration's three symlinks are created
  there (the `load_module` lines the bouncer/VTS need). A `modules-enabled/`
  you populate yourself is left alone.

This works because we enrich the base's config *template*
(`/usr/local/etc/nginx`); the base's `init-config` s6 oneshot runs
before nginx and only does
`[ -z "$(ls -A /etc/nginx)" ] && cp -rp /usr/local/etc/nginx/* /etc/nginx/`.
No custom entrypoint, no clobbering.

The one deliberate exception to *seed-only-if-`/etc/nginx`-empty*: a
second s6 oneshot, `ensure-modules-enabled` (ordered **after**
`init-config`, **before** nginx), recreates the `modules-enabled/`
symlinks when **that directory** is empty or absent — even on a
populated bring-your-own `/etc/nginx`, where `init-config` does nothing.
It's still seed-if-empty + never-clobber, just at `modules-enabled/`
granularity: a non-empty `modules-enabled/` (your own files, or a
deliberately removed symlink like vts) is left untouched. It never
edits your `nginx.conf` — you still add the
`include /etc/nginx/modules-enabled/*.conf;` line yourself.

#### Required for the integration to work

If you **import your own `/etc/nginx`** (so nothing is seeded), these are
the *only* things you must add **to `/etc/nginx`** for the CrowdSec
bouncer + VTS + nginx-ui to function. Names match a normal Debian
baremetal install — nothing `buco`-branded:

| File | Why it's required |
|---|---|
| `modules-enabled/{10-mod-http-ndk,50-mod-http-lua,90-mod-http-vhost-traffic-status}.conf` — **symlinks** | `load_module` for NDK+lua (the bouncer) and VTS (the dashboard). Debian convention: the real one-line files are image-owned at `/usr/share/nginx/modules-available/mod-http-{ndk,lua,vhost-traffic-status}.conf` (like the `.so` files at `/usr/lib/nginx/modules`, outside `/etc/nginx`); `modules-enabled/` holds the numbered symlinks (NDK `10-` must precede lua `50-`; VTS `90-` is independent). **Auto-created on container start** whenever `modules-enabled/` is empty or absent — including a populated bring-your-own `/etc/nginx` (the `ensure-modules-enabled` oneshot). You only create them by hand if you manage a **non-empty** `modules-enabled/` yourself (it's then left untouched): add ours alongside — `ln -s /usr/share/nginx/modules-available/mod-http-ndk.conf modules-enabled/10-mod-http-ndk.conf` (likewise `50-…-lua`, `90-…-vhost-traffic-status`). Either way your `nginx.conf` still needs the `include` line (next row). |
| `include /etc/nginx/modules-enabled/*.conf;` at the **main** context of your `nginx.conf` | `load_module` is only valid in the main context, never `http{}`. Debian's stock `nginx.conf` already has this line; nginx.org's does not — add it once. |
| `include /etc/nginx/conf.d/*.conf;` inside `http{}` | Standard; pulls in everything below. |
| `conf.d/crowdsec_nginx.conf` | Wires the lua bouncer into nginx. Ships in the bouncer package, **not this repo** — grab it from a seeded run: `docker cp nginx:/etc/nginx/conf.d/crowdsec_nginx.conf .` (it's byte-for-byte the file `apt install crowdsec-nginx-bouncer` installs). It *reads* the bouncer's runtime config at `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` — a bind mount, **not** an `/etc/nginx` file; see the note below. |
| `conf.d/realip.conf` | Without it the bouncer sees the Docker gateway IP for every request and is effectively useless (it'd ban/allow the gateway, not real clients). |
| `conf.d/resolver.conf` | The only docker-ism. Not the usual nginx case: a static `proxy_pass http://name` resolves once at startup via the system resolver (`/etc/resolv.conf`), so it needs no `resolver`. But the bouncer reaches LAPI/AppSec through the **lua cosocket** client (`lua-resty-http`), which **ignores `/etc/resolv.conf`** and resolves hostnames *only* via nginx's `resolver` directive. So `resolver 127.0.0.11;` (Docker's embedded DNS) is mandatory to look up the `crowdsec` service name. Unneeded on baremetal where LAPI is the literal IP `127.0.0.1` (no name to resolve). |
| `conf.d/vts.conf` | VTS zone + the `:9113/status` HTML dashboard. Drop this (and `90-mod-http-vhost-traffic-status.conf`) if you don't want the traffic dashboard — the bouncer still works without it. |

Everything is in this repo under `conf/` (except `crowdsec_nginx.conf`,
which is a package file — see above). The repo's `conf/nginx.conf` is
just a plain reference skeleton; you don't need it if you bring your own.

**Beyond `/etc/nginx` — the bouncers' own runtime config.** The table
above is the `/etc/nginx` side only. The lua bouncer also reads
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` and the firewall
bouncer `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` — these
are **not** `/etc/nginx` files, so they're not in the table. They're the
repo-shipped `crowdsec_nginx-bouncer.conf` / `crowdsec_firewall-bouncer.yaml`,
bind-mounted by `docker-compose.yml` and always present whether or not
you bring your own `/etc/nginx`. You don't create them; you only set the
API key in each — see [Path A step 1](#path-a--fresh-install) /
[Path B step 8](#path-b--migrate-an-existing-install). Without the right
key there, `crowdsec_nginx.conf` loads fine but the bouncer can't
authenticate to LAPI.

#### Optional extras

Shipped as examples under `conf/optional/`, **not** seeded — copy into
your `/etc/nginx/` only if you want them:

- `optional/conf.d/ratelimit.conf` + `optional/snippets/ratelimit.conf`
  — connection/request rate-limit zones, opted into per-server with
  `include snippets/ratelimit.conf;` inside a `server {}` block.
- `optional/snippets/security-txt.conf` — serves
  `/.well-known/security.txt` (copy the repo's `www/` sample to the host
  `/var/www`, then edit `/var/www/well-known/security.txt` for your
  contact details), opted in per-server the same way.

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

certwarden :4055 ──writes /certs/──▶ host /etc/ssl/domains/
                 ──POST reload────▶  nginx /api/nginx/reload
```

The reverse proxy (80/443) and the user-facing UIs — VTS dashboard
`:9113`, CrowdSec web UI, Certwarden UI `:4050`/`:4055` — bind to all
interfaces; **gate them at your host firewall**. Internal/sensitive
ports stay loopback-only: CrowdSec LAPI `:8080`, Certwarden ACME
`:4060` and pprof `:4065`/`:4070`. All services share the `proxy_net` bridge network and resolve
each other by service name — except the firewall bouncer, which runs
with `network_mode: host` so it can rewrite iptables, and reaches LAPI
via the loopback-published `127.0.0.1:8080`.

The CrowdSec web UI authenticates to LAPI with **machine credentials**
(`CROWDSEC_UI_USER` / `CROWDSEC_UI_PASSWORD`), not a bouncer API key, so
that machine has to be registered once (during [Setup](#setup)).

### Host paths

The nginx container uses **absolute Debian-style paths**, bind-mounted
from the host:

| Container          | Host                | Owner                              |
|--------------------|---------------------|------------------------------------|
| `/etc/nginx`       | `/etc/nginx`        | you — drop your config here        |
| `/var/log/nginx`   | `/var/log/nginx`    | nginx writes, crowdsec reads (RO)  |
| `/etc/ssl/domains` | `/etc/ssl/domains`  | certwarden writes (via its `/certs` mount), nginx reads (RO)|
| `/var/www`         | `/var/www`          | you — static web root (`security.txt`, etc.) |

CrowdSec uses two flat bind dirs next to `docker-compose.yml`:
`crowdsec_config/` (version-controlled — acquis, whitelists,
appsec-config; hub-installed collections also land here at runtime) and
`crowdsec_data/` (runtime LAPI state DB — gitignored). The static web
root is the absolute host path `/var/www` (same Debian-style convention
as `/etc/nginx` — the repo's `www/` is just a sample to copy there).
Everything else (nginx-ui state, web-ui data, certwarden data) likewise
stays in relative bind-mount dirs next to `docker-compose.yml` — all
gitignored.

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

Sample whitelists ship version-controlled in `crowdsec_config/`. They're
**examples** — edit them for your environment (none contain real IPs).

| File | Stage | What it does |
|---|---|---|
| `parsers/s02-enrich/whitelists.yaml` (`my/whitelists`) | parser | Trusted IP/CIDR sources — short-circuits BOTH log scenarios AND AppSec. Active automatically (parser whitelists need no wiring). |
| `parsers/s02-enrich/nginx-ui-api-whitelist.yaml` | parser | Drops nginx-ui's own `/api/*` 403 bursts (false positive when logged out) before any scenario scores them. |
| `appsec-rules/whitelists.yaml` (`my/appsec-allow-path`) | AppSec in-band | Exempts a path from **specific** WAF rules via `on_match: allow` + `target_rules:`. Self-attaching — `acquis.yaml` stays on stock `crowdsecurity/appsec-default`, no custom appsec-config. |

**Cleanest way to whitelist a path from rules** (your earlier question):

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
every Sunday at 00:00 UTC, picking up `uozi/nginx-ui:latest` (including
whatever nginx version it ships) and recompiling the lua stack + VTS
against it. If an upstream change ever breaks compatibility the build
fails (the last good image keeps running) — so "upgrading" is just
`docker compose pull && docker compose up -d`.

### Reconciling the bind-mounted bouncer configs

The two bouncer configs are **bind-mounted from the repo**
(`crowdsec_nginx-bouncer.conf`, `crowdsec_firewall-bouncer.yaml`), so they
**shadow** the image/package defaults — a `pull` updates the bouncer
*code* but never your static config. Schema drift is rare and usually
benign (a missing new key just keeps the old default), but a
renamed/removed/new-required key can change or break behaviour, and the
build-time `nginx -t` guard does **not** validate bouncer config — it
surfaces at runtime (check `docker compose logs crowdsec` /
`crowdsec-firewall-bouncer`). The current upstream default always sits
at the same path inside the freshly-pulled image, so after a notable
CrowdSec bump, diff and merge in anything new (keep your `API_KEY` and
the `crowdsec:8080` / `127.0.0.1:8080` wiring):

```bash
# nginx bouncer — vs the .deb default baked into the pulled image
docker run --rm --entrypoint cat ghcr.io/buco7854/nginx:latest \
  /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf | diff - crowdsec_nginx-bouncer.conf

# firewall bouncer — vs the .deb default baked into the pulled image
docker run --rm --entrypoint cat ghcr.io/buco7854/crowdsec-firewall-bouncer:latest \
  /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml | diff - crowdsec_firewall-bouncer.yaml
```

This is the containerised equivalent of baremetal `apt`'s `.dpkg-dist`
reconciliation — except the reference default is always one `docker run`
away, never lost.

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
│   ├── modules-available/{mod-http-ndk, mod-http-lua,
│   │                      mod-http-vhost-traffic-status}.conf
│   │                          # image symlinks these into modules-enabled/
│   ├── conf.d/{realip, resolver, vts}.conf
│   │                          # crowdsec_nginx.conf comes from the .deb
│   └── optional/             # NOT seeded — opt-in examples (see README)
│       ├── conf.d/ratelimit.conf
│       └── snippets/{ratelimit.conf, security-txt.conf}
├── crowdsec_nginx-bouncer.conf                  # nginx Lua bouncer (mounted into nginx)
├── crowdsec_firewall-bouncer.yaml         # firewall bouncer (mounted into firewall-bouncer)
├── crowdsec_config/                       # mounted into the crowdsec container (/etc/crowdsec)
│   ├── acquis.yaml                        # nginx logs + AppSec listener (stock appsec-default)
│   ├── profiles.yaml                      # escalating-ban remediation (sample)
│   ├── appsec-rules/whitelists.yaml       # my/appsec-allow-path (target_rules sample)
│   ├── parsers/s02-enrich/whitelists.yaml # my/whitelists (IP/CIDR sample)
│   └── parsers/s02-enrich/nginx-ui-api-whitelist.yaml  # nginx-ui /api/* 403 false-positive
│                                          # crowdsec_data/ = runtime LAPI state (gitignored)
├── www/well-known/security.txt          # sample — copy to host /var/www/
└── scripts/{write_cert.sh, maintenance_nginx_ui.sh}
```
