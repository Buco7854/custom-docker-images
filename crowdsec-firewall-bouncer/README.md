# buco7854/crowdsec-firewall-bouncer

CrowdSec publishes **no official Docker image** for the
[firewall bouncer](https://github.com/crowdsecurity/cs-firewall-bouncer)
— it ships only as a host package (deb/rpm), because it rewrites the
host firewall and a container was never the upstream-supported shape.
Only community images exist. The nginx stack's `docker-compose.yml` in
this repo previously pointed at `crowdsecurity/crowdsec-firewall-bouncer`,
which has never existed on any registry — this image is the fix.

| Image | Source | Schedule |
|-------|--------|----------|
| `ghcr.io/buco7854/crowdsec-firewall-bouncer:latest` | this folder's [`Dockerfile`](./Dockerfile) | Weekly Sun 00:00 UTC |
| `ghcr.io/buco7854/crowdsec-firewall-bouncer:<sha>`  | tagged on every push to `main`             | per-commit            |

## How it's built

Same supply-chain posture as this repo's nginx image:

- The bouncer comes from CrowdSec's **official packagecloud `.deb`**,
  **GPG-verified** against the same pinned fingerprint the nginx image
  asserts (a key rotation fails the build loudly).
- The `.deb` is **extracted** (`dpkg-deb -x`), not `apt install`ed: the
  package's postinst only enables a systemd unit and tries to
  self-register against a local LAPI — neither makes sense (or works) in
  a container. The static Go binary is run directly.
- The `-iptables` variant is pulled (the stack's
  `crowdsec_firewall-bouncer.yaml` uses `mode: iptables`); `iptables` +
  `ipset` (its real runtime deps) come straight from Debian.
- A build-time `crowdsec-firewall-bouncer -V` smoke test runs the binary
  on the **target arch** under QEMU — fail-loud, like the nginx image's
  `nginx -t` guard.

## Build args

| Arg | Default | Purpose |
|-----|---------|---------|
| `CS_FW_BOUNCER_FLAVOR`     | `iptables` | `iptables` or `nftables`. nftables also needs `mode: nftables` in the bouncer yaml. |
| `CS_FW_BOUNCER_VERSION`    | *(empty)*  | Pin a reproducible build, e.g. `0.0.31`. Empty tracks the repo's current. |
| `CROWDSEC_DEBIAN_RELEASE`  | `bookworm` | packagecloud release the `.deb` is fetched from. |
| `CROWDSEC_GPG_FINGERPRINT` | pinned     | Asserted against CrowdSec's packagecloud signing key. |

## Usage

Already wired into [`../nginx/docker-compose.yml`](../nginx/docker-compose.yml):
it runs `network_mode: host` with `cap_add: NET_ADMIN` (the only cap it
needs — it edits iptables/ipset via netlink and opens no raw sockets) so
it can write the host's iptables, reaches LAPI via the loopback-published
`127.0.0.1:8080`, and bind-mounts
[`../nginx/crowdsec_firewall-bouncer.yaml`](../nginx/crowdsec_firewall-bouncer.yaml)
over the image's default config. Standalone:

```bash
docker run -d --name crowdsec-firewall-bouncer \
  --network host --cap-add NET_ADMIN \
  -v $PWD/crowdsec_firewall-bouncer.yaml:/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml:ro \
  ghcr.io/buco7854/crowdsec-firewall-bouncer:latest
```

## Host-firewall caveat

The in-container `iptables` manipulates the **shared host kernel**
netfilter. Debian bookworm's `iptables` uses the nft backend
(`iptables-nft`), which matches a modern host. On a legacy-backend host
the rules may land in the wrong table — rebuild with the nftables
flavour (`--build-arg CS_FW_BOUNCER_FLAVOR=nftables`, plus
`mode: nftables` in the yaml) or switch the host to `iptables-legacy`.
