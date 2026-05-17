# custom-docker-images
Automated Docker image builder. Builds and publishes images to GHCR on a daily schedule.
## Images
| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/yagpdb:latest` | [botlabs-gg/yagpdb](https://github.com/botlabs-gg/yagpdb) | Daily 2:00 UTC |
| `ghcr.io/buco7854/caddy-cloudflare:latest` | [caddy](https://hub.docker.com/_/caddy) + [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) | Daily 3:00 UTC |
| `ghcr.io/buco7854/postgres:<tag>` | `./postgres/<tag>/` | Daily 3:00 UTC |
| `ghcr.io/buco7854/nginx:latest` | [uozi/nginx-ui](https://hub.docker.com/r/uozi/nginx-ui) + Debian lua module + [crowdsec-nginx-bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer) + [nginx-module-vts](https://github.com/vozlt/nginx-module-vts) | Weekly Sun 00:00 UTC |
| `ghcr.io/buco7854/crowdsec-firewall-bouncer:latest` | [cs-firewall-bouncer](https://github.com/crowdsecurity/cs-firewall-bouncer) — GPG-verified packagecloud `.deb` (no official upstream Docker image) | Weekly Sun 00:00 UTC |
## Custom Postgres images
| Tag | Base | Extras |
|-----|------|--------|
| `15-cron` | postgres:15-trixie | pg_cron |
| `15-cron-bktree` | postgres:15-trixie | pg_cron + bktree |
| `16-cron` | postgres:16-trixie | pg_cron |
| `18-bktree` | postgres:18-trixie | bktree |
To add a new image, just create a new folder under `postgres/` with a `Dockerfile` — it will be picked up automatically on the next run.

> **Collation caveat (bookworm → trixie):** these moved from a bookworm base to trixie, which bumps glibc (2.36 → 2.41) and ICU (72 → 76). The text collation order changes between those versions, so a `PGDATA` volume **first created on the old bookworm image** will log a `collation version mismatch` warning and may have subtly wrong results / unique-constraint violations on collated (text) indexes until you `REINDEX`. Fresh volumes are unaffected. On an existing volume, after pulling the trixie image run, per database: `REINDEX DATABASE <db>;` then `ALTER DATABASE <db> REFRESH COLLATION VERSION;` (and the same for `template1`). No action needed for new deployments.

## nginx
[`uozi/nginx-ui`](https://hub.docker.com/r/uozi/nginx-ui) with two dynamic modules added to its stock nginx: Debian's lua module (so the [CrowdSec lua bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer) runs) and a compiled [nginx-module-vts](https://github.com/vozlt/nginx-module-vts) serving a custom HTML traffic dashboard (no Prometheus output). No OpenResty — its apt repo lags Debian releases by many months. Published to GHCR as `ghcr.io/buco7854/nginx`. See [`nginx/`](./nginx) for the Dockerfile + image-specific README, and [`nginx/example/`](./nginx/example) for a ready-to-run compose stack (nginx + crowdsec + firewall bouncer + web UI + certwarden).

## crowdsec-firewall-bouncer
CrowdSec ships the [firewall bouncer](https://github.com/crowdsecurity/cs-firewall-bouncer) **only as a host package** — there is no official Docker image for it (only community ones), so the nginx stack's `docker-compose.yml` previously referenced an image that never existed. This builds one from CrowdSec's official packagecloud `.deb` (GPG-verified against the same pinned fingerprint as the nginx image, then extracted — no postinst/systemd), with `iptables` + `ipset` so the stack's `mode: iptables` works. Build the nftables variant with `--build-arg CS_FW_BOUNCER_FLAVOR=nftables`. Published to GHCR as `ghcr.io/buco7854/crowdsec-firewall-bouncer`. See [`crowdsec-firewall-bouncer/`](./crowdsec-firewall-bouncer) for the Dockerfile and image README; it runs `network_mode: host` with `NET_ADMIN` to rewrite the host firewall (already wired in [`nginx/example/docker-compose.yml`](./nginx/example/docker-compose.yml)).

## Usage
```bash
docker pull ghcr.io/buco7854/yagpdb:latest
docker pull ghcr.io/buco7854/caddy-cloudflare:latest
docker pull ghcr.io/buco7854/postgres:16-cron
docker pull ghcr.io/buco7854/nginx:latest
docker pull ghcr.io/buco7854/crowdsec-firewall-bouncer:latest
```
> Packages are private by default (if repo is private in my case it is public). To make them public: GitHub profile → Packages → select image → Package Settings → change visibility.
