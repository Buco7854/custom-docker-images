# custom-docker-images
Automated Docker image builder. Builds and publishes images to GHCR on a daily schedule.
## Images
| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/yagpdb:latest` | [botlabs-gg/yagpdb](https://github.com/botlabs-gg/yagpdb) | Daily 2:00 UTC |
| `ghcr.io/buco7854/caddy-cloudflare:latest` | [caddy](https://hub.docker.com/_/caddy) + [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) | Daily 3:00 UTC |
| `ghcr.io/buco7854/postgres:<tag>` | `./postgres/<tag>/` | Daily 3:00 UTC |
| `buco7854/nginx:latest` (Docker Hub) | [uozi/nginx-ui](https://hub.docker.com/r/uozi/nginx-ui) + Debian lua module + [crowdsec-nginx-bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer) + [nginx-module-vts](https://github.com/vozlt/nginx-module-vts) | Weekly Sun 00:00 UTC |
## Custom Postgres images
| Tag | Base | Extras |
|-----|------|--------|
| `15-cron` | postgres:15-bookworm | pg_cron |
| `15-cron-bktree` | postgres:15-bookworm | pg_cron + bktree |
| `16-cron` | postgres:16-bookworm | pg_cron |
| `18-bktree` | postgres:18-bookworm | bktree |
To add a new image, just create a new folder under `postgres/` with a `Dockerfile` — it will be picked up automatically on the next run.

## nginx
[`uozi/nginx-ui`](https://hub.docker.com/r/uozi/nginx-ui) with two dynamic modules added to its stock nginx: Debian's lua module (so the [CrowdSec lua bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer) runs) and a compiled [nginx-module-vts](https://github.com/vozlt/nginx-module-vts) serving a custom HTML traffic dashboard (no Prometheus output). No OpenResty — its apt repo lags Debian releases by many months. Published to Docker Hub as `buco7854/nginx`. See [`nginx/`](./nginx) for the Dockerfile, image-specific README, and a ready-to-run `docker-compose.yml` (nginx + crowdsec + firewall bouncer + web UI + prometheus/grafana for CrowdSec + certwarden).

## Usage
```bash
docker pull ghcr.io/buco7854/yagpdb:latest
docker pull ghcr.io/buco7854/caddy-cloudflare:latest
docker pull ghcr.io/buco7854/postgres:16-cron
docker pull buco7854/nginx:latest
```
> Packages are private by default (if repo is private in my case it is public). To make them public: GitHub profile → Packages → select image → Package Settings → change visibility.
