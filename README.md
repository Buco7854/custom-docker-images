# custom-docker-images

Automated Docker image builder. Builds and publishes images to GHCR on a daily schedule.

## Images

| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/yagpdb:latest` | [botlabs-gg/yagpdb](https://github.com/botlabs-gg/yagpdb) | Daily 2:00 UTC |
| `ghcr.io/buco7854/postgres:<tag>` | `./postgres/<tag>/` | Daily 3:00 UTC |

## Custom Postgres images

| Tag | Base | Extras |
|-----|------|--------|
| `15-cron` | postgres:15-bookworm | pg_cron |
| `15-cron-bktree` | postgres:15-bookworm | pg_cron + bktree |
| `16-cron` | postgres:16-bookworm | pg_cron |
| `18-bktree` | postgres:18-bookworm | bktree |

To add a new image, just create a new folder under `postgres/` with a `Dockerfile` — it will be picked up automatically on the next run.

## Usage

```bash
docker pull ghcr.io/buco7854/yagpdb:latest
docker pull ghcr.io/buco7854/postgres:16-cron
```

> Packages are private by default. To make them public: GitHub profile → Packages → select image → Package Settings → change visibility.
