# custom-docker-images
Automated Docker image builder. Builds and publishes images to GHCR on a daily schedule.
## Images
| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/yagpdb:latest` | [botlabs-gg/yagpdb](https://github.com/botlabs-gg/yagpdb) | Daily 2:00 UTC |
| `ghcr.io/buco7854/caddy-cloudflare:latest` | [caddy](https://hub.docker.com/_/caddy) + [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) | Daily 3:00 UTC |
| `ghcr.io/buco7854/postgres:<tag>` | `./postgres/<tag>/` | Daily 3:00 UTC |
| `ghcr.io/buco7854/nginx-ui-vts:latest` | [uozi/nginx-ui](https://hub.docker.com/r/uozi/nginx-ui) + [vozlt/nginx-module-vts](https://github.com/vozlt/nginx-module-vts) | Daily 3:00 UTC |
## Custom Postgres images
| Tag | Base | Extras |
|-----|------|--------|
| `15-cron` | postgres:15-bookworm | pg_cron |
| `15-cron-bktree` | postgres:15-bookworm | pg_cron + bktree |
| `16-cron` | postgres:16-bookworm | pg_cron |
| `18-bktree` | postgres:18-bookworm | bktree |
To add a new image, just create a new folder under `postgres/` with a `Dockerfile` — it will be picked up automatically on the next run.

## nginx-ui-vts
[`uozi/nginx-ui`](https://hub.docker.com/r/uozi/nginx-ui) with the [VTS module](https://github.com/vozlt/nginx-module-vts) compiled as a dynamic module against the exact nginx version shipped by the upstream image. Adds:
- A custom HTML dashboard baked into the VTS module
- A tiny key-protected HTTP API to trigger `nginx -s reload` from other containers (so e.g. Certwarden can reload nginx after issuing a cert)
- `supercronic` reading a crontab file (path: `$CRONTAB_FILE`, default `/etc/cron.d/default.crontab`) — mount your own to override
- Bundled maintenance jobs: SQLite VACUUM of the nginx-ui DB, `security.txt` Expires-renewal, abandoned-body cleanup

See [`examples/`](./examples) for a full compose stack with Certwarden + CrowdSec.
## Usage
```bash
docker pull ghcr.io/buco7854/yagpdb:latest
docker pull ghcr.io/buco7854/caddy-cloudflare:latest
docker pull ghcr.io/buco7854/postgres:16-cron
```
> Packages are private by default (if repo is private in my case it is public). To make them public: GitHub profile → Packages → select image → Package Settings → change visibility.
