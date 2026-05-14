# Reverse-proxy stack — example

A docker-compose setup for nginx-ui-vts + Certwarden + CrowdSec (LAPI + AppSec)
+ nginx lua bouncer + firewall bouncer + CrowdSec web UI.

Design choice: things an admin SSH-edits live at their canonical host paths
(`/etc/nginx`, `/etc/crowdsec`, `/var/log/nginx`, `/etc/ssl/<domain>/`).
App state lives in `<thing>_data/` directories next to the compose file so
the stack stays portable.

## Host directory map

### Absolute (canonical) paths

| Host path | Container path | Owner |
|---|---|---|
| `/etc/nginx/` | `/etc/nginx/` (nginx-ui) | full nginx config tree |
| `/etc/crowdsec/` | `/etc/crowdsec/` (crowdsec) | CrowdSec config per upstream docs |
| `/etc/ssl/<domain>/` | `/etc/ssl/<domain>/` (nginx-ui RO, certwarden RW) | TLS material per domain |
| `/var/log/nginx/` | `/var/log/nginx/` (nginx-ui RW, crowdsec RO) | nginx logs |

### Relative paths (created next to this compose file)

| Host path | Container path | Owner |
|---|---|---|
| `./nginx_ui_data/` | `/etc/nginx-ui/` (nginx-ui) | nginx-ui SQLite DB |
| `./crowdsec_data/` | `/var/lib/crowdsec/` (crowdsec) | LAPI SQLite DB |
| `./crowdsec_web_ui_data/` | `/app/data/` (crowdsec-web-ui) | web UI state — *separate* from LAPI DB |
| `./certwarden_data/` | `/app/data/` (certwarden) | Certwarden DB + ACME account keys |
| `./certwarden_scripts/` | `/scripts/` (certwarden, ro) | post-issuance hooks (shipped in this repo) |
| `./bouncer_templates/{ban,captcha}.html` | `/var/lib/crowdsec/lua/templates/...` (nginx-ui, ro) | lua bouncer ban / captcha pages |
| `./www/` | `/var/www/` (nginx-ui) | served content + ACME webroot |
| `./nginx_crontab` | `/etc/cron.d/nginx-ui.crontab` (nginx-ui, ro) | supercronic schedule |

Docker auto-creates the relative dirs on first start.

## What's in this directory

```
.
├── README.md                         (this file)
├── docker-compose.yml
├── .env.example
├── nginx_crontab                     copied as a single file into the container
├── certwarden_scripts/               bind-mounted into certwarden
│   └── write_cert.sh
├── bouncer_templates/                lua bouncer ban / captcha pages
│   ├── ban.html
│   └── captcha.html
└── etc/                              copy contents to /etc on the host
    ├── nginx/
    │   ├── nginx.conf                works as-is; edit to taste
    │   ├── conf.d/
    │   ├── sites-available/
    │   ├── sites-enabled/
    │   └── snippets/
    └── crowdsec/
        ├── acquis.yaml               nginx log inputs + AppSec listener
        ├── parsers/s02-enrich/
        │   └── whitelists.yaml       starter whitelist (localhost, RFC1918, docker0)
        └── bouncers/
            └── crowdsec-firewall-bouncer.yaml
```

## First-time setup

```sh
# 1. Seed configs into /etc.
sudo cp -rn etc/. /etc/

# 2. Create the logs dir on the host (the only writable absolute path
#    that isn't auto-managed). /etc/ssl exists already on any standard distro.
sudo mkdir -p /var/log/nginx

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

1. Issue a cert through Certwarden's UI (port 4055). Its post-issuance hook writes
   `/etc/ssl/<domain>/fullchain.pem` and `/etc/ssl/<domain>/privkey.pem`.
2. Add a site config under `/etc/nginx/sites-available/<domain>.conf`, symlink into
   `sites-enabled/`, or use the nginx-ui web UI (port 9000).
3. Reload nginx — nginx-ui has a button, or:
   `curl -X POST -H "X-API-Key: $RELOAD_API_KEY" http://127.0.0.1:9010/reload`

## Caveats

- **`/etc/ssl` is bind-mounted wholesale.** The host must have the
  `ca-certificates` package installed (standard on any server distro) so the
  containers still verify outbound TLS via `/etc/ssl/certs/ca-certificates.crt`.
- **The host must not already run a system nginx or crowdsec.** Their config
  dirs would collide.
- **`/var/log/nginx` is shared** between nginx-ui (rw) and crowdsec (ro). Host
  logrotate is fine — nginx-ui reopens log fds via the reload API.
- **Backups:** absolute paths to grab are `/etc/{nginx,crowdsec,ssl}`. Relative
  paths are everything ending in `_data/` next to this compose file, plus
  `./www/`. `/var/log/nginx/` you can decide on case-by-case.

## Custom ban / captcha pages

Edit `./bouncer_templates/ban.html` and `./bouncer_templates/captcha.html`
in place — they're bind-mounted over the image defaults. The captcha
template must contain `{{captcha_site_key}}`, which the bouncer substitutes
with whatever you set as `CROWDSEC_CAPTCHA_SITE_KEY`. The starter
`captcha.html` is wired for Cloudflare Turnstile; swap the script src and
the element class for hcaptcha or reCAPTCHA if you prefer.
