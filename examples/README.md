# Reverse-proxy stack — example

A docker-compose setup for nginx-ui-vts + Certwarden + CrowdSec (LAPI + AppSec)
+ nginx lua bouncer + firewall bouncer + CrowdSec web UI.

Design choice: **files live on the host at their canonical paths**, same as
a non-containerised install. `/etc/nginx/nginx.conf` is `/etc/nginx/nginx.conf`,
`/var/log/nginx/access.log` is `/var/log/nginx/access.log`. SSH in, `vi`,
done. The compose file just glues the containers to those paths.

## Host directory map

| Host path | Container path | Owner |
|---|---|---|
| `/etc/nginx/` | `/etc/nginx/` (nginx-ui) | full nginx config tree |
| `/etc/nginx-ui/` | `/etc/nginx-ui/` (nginx-ui) | nginx-ui DB + crontab + optional template overrides |
| `/etc/crowdsec/` | `/etc/crowdsec/` (crowdsec) | CrowdSec config per upstream docs |
| `/etc/certwarden/scripts/` | `/scripts/` (certwarden) | post-issuance hook scripts |
| `/etc/ssl/<domain>/` | `/etc/ssl/<domain>/` (nginx-ui RO, certwarden RW) | TLS material per domain |
| `/var/log/nginx/` | `/var/log/nginx/` (nginx-ui RW, crowdsec RO) | nginx logs |
| `/var/lib/crowdsec/` | `/var/lib/crowdsec/` (crowdsec) | LAPI SQLite DB |
| `/var/lib/crowdsec-web-ui/` | `/app/data/` (crowdsec-web-ui) | web UI state (separate DB) |
| `/var/lib/certwarden/` | `/app/data/` (certwarden) | Certwarden DB + ACME account keys |
| `/var/www/` | `/var/www/` (nginx-ui) | served content, ACME webroot |

## What's in this directory

```
.
├── README.md                         (this file)
├── docker-compose.yml
├── .env.example
└── etc/                              copy contents to /etc on the host
    ├── nginx/
    │   ├── nginx.conf                works as-is; edit to taste
    │   ├── conf.d/
    │   ├── sites-available/
    │   ├── sites-enabled/
    │   └── snippets/
    ├── nginx-ui/
    │   └── crontab                   read by the nginx-ui container's supercronic
    ├── crowdsec/
    │   ├── acquis.yaml               nginx log inputs + AppSec listener
    │   ├── parsers/s02-enrich/
    │   │   └── whitelists.yaml       starter whitelist (localhost, RFC1918, docker0)
    │   └── bouncers/
    │       └── crowdsec-firewall-bouncer.yaml
    └── certwarden/
        └── scripts/
            └── write_cert.sh
```

## First-time setup

```sh
# 1. Seed configs into /etc.
sudo cp -rn etc/. /etc/

# 2. Create the writable state dirs (host owns these).
sudo mkdir -p /var/log/nginx /var/www \
              /var/lib/crowdsec \
              /var/lib/crowdsec-web-ui \
              /var/lib/certwarden

# 3. Fill in .env.
cp .env.example .env
$EDITOR .env

# 4. Start CrowdSec alone so we can register bouncers against it.
docker compose up -d crowdsec

# 5. Register the bouncers — copy each key into the right place.
docker exec crowdsec cscli bouncers add nginx-bouncer
#   ^ paste this key into .env as CROWDSEC_BOUNCER_API_KEY

docker exec crowdsec cscli bouncers add firewall-bouncer
#   ^ paste this key into /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml (api_key:)

# 6. Bring up the rest.
docker compose up -d
```

## Adding a domain

1. Configure Certwarden (web UI at port 4055) to issue a cert for `example.com`. It writes
   `/etc/ssl/example.com/fullchain.pem` and `/etc/ssl/example.com/privkey.pem` via the
   post-issuance script.
2. Add a site config under `/etc/nginx/sites-available/example.com.conf`, symlink into
   `sites-enabled/`, or use the nginx-ui web UI (port 9000).
3. Reload nginx — the nginx-ui UI has a button, or:
   `curl -X POST -H "X-API-Key: $RELOAD_API_KEY" http://127.0.0.1:9010/reload`

## Caveats

- **`/etc/ssl` is bind-mounted wholesale.** The host must have the
  `ca-certificates` package (standard on any server distro) so the containers can
  still verify outbound TLS via `/etc/ssl/certs/ca-certificates.crt`.
- **The host must not already run a system nginx or crowdsec.** Their config dirs
  would collide.
- **`/var/log/nginx` is shared** between the nginx-ui container (rw, writes logs)
  and the crowdsec container (ro, parses them). Logrotate on the host is fine —
  nginx-ui reopens log fds via the reload API.
- **Backups:** the four host paths you care about are `/etc/{nginx,nginx-ui,crowdsec,certwarden,ssl}` and `/var/lib/{crowdsec,crowdsec-web-ui,certwarden}`. `/var/log/nginx` and `/var/www` you can decide on case-by-case.

## Custom ban / captcha pages

The image ships sensible defaults. To override, drop your own HTML at:
```
/etc/nginx-ui/bouncer-templates/ban.html
/etc/nginx-ui/bouncer-templates/captcha.html
```
then uncomment the two corresponding bind mounts in `docker-compose.yml`. The
captcha template must contain `{{captcha_site_key}}` — see the bouncer docs.
