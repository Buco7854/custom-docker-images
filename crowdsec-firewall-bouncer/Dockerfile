# syntax=docker/dockerfile:1.7
#
# buco7854/crowdsec-firewall-bouncer — CrowdSec does NOT publish an
# official Docker image for the firewall bouncer. It ships ONLY as a host
# package (deb/rpm) because it rewrites the host firewall, so a container
# was never the upstream-supported shape. This stack's
# docker-compose.yml needs it as a container anyway (network_mode: host +
# NET_ADMIN so it can write the host's iptables), so we build one
# — the compose file previously pointed at a `crowdsecurity/...` image
# that has never existed on any registry.
#
# Same supply-chain posture as this repo's nginx image: the bouncer comes
# from CrowdSec's official packagecloud .deb, GPG-verified against the
# pinned fingerprint, then EXTRACTED (dpkg-deb -x) rather than
# `apt install`ed. The package's postinst only enables a systemd unit and
# tries to self-register against a local LAPI — neither makes sense (or
# works) in a container; we run the static binary directly instead.
#
# We pull the `-iptables` variant because the stack's
# crowdsec_firewall-bouncer.yaml uses `mode: iptables`; iptables + ipset
# (its real runtime deps) come straight from Debian. Build the nftables
# flavour with --build-arg CS_FW_BOUNCER_FLAVOR=nftables (also flip
# `mode:` in the yaml) — then nftables is the dep instead.
#
# Host-firewall caveat: the in-container iptables manipulates the SHARED
# host kernel netfilter. Debian trixie's iptables uses the nft backend
# (iptables-nft); this matches a modern host. On a legacy-backend host,
# rebuild with the nftables flavour or run iptables-legacy on the host.

FROM debian:trixie-slim

# Same packagecloud signing key as the nginx image's CrowdSec bouncer
# step — asserted below so a key rotation fails the build LOUDLY instead
# of silently trusting a new key.
ARG CROWDSEC_GPG_FINGERPRINT=6A89E3C2303A901A889971D3376ED5326E93CD0C
# This is the packagecloud APT repo release, deliberately DECOUPLED from
# the trixie base above: CrowdSec's packagecloud doesn't track every
# Debian release (no trixie repo), and the bouncer .deb is a static Go
# binary, so the release it was built for is irrelevant to the trixie
# runtime — it runs identically. The build-time `-V` smoke test proves
# it on the trixie base before the image ships.
ARG CROWDSEC_DEBIAN_RELEASE=bookworm
# iptables (matches the stack's `mode: iptables`) or nftables.
ARG CS_FW_BOUNCER_FLAVOR=iptables
# Pin a reproducible build, e.g. --build-arg CS_FW_BOUNCER_VERSION=0.0.31
# (empty = whatever the repo currently serves; the weekly rebuild then
# tracks upstream automatically).
ARG CS_FW_BOUNCER_VERSION=

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    case "${CS_FW_BOUNCER_FLAVOR}" in \
        iptables) FW_PKGS="iptables ipset" ;; \
        nftables) FW_PKGS="nftables" ;; \
        *) echo "FATAL: CS_FW_BOUNCER_FLAVOR must be iptables|nftables (got '${CS_FW_BOUNCER_FLAVOR}')" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    # ${FW_PKGS} + ca-certificates are the only RUNTIME deps. curl/gnupg
    # are build-only (add the verified apt repo + fetch the .deb) and are
    # purged before the layer ends.
    apt-get install -y --no-install-recommends ca-certificates ${FW_PKGS}; \
    apt-get install -y --no-install-recommends curl gnupg; \
    \
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey -o /tmp/cs.key; \
    fpr="$(gpg --show-keys --with-fingerprint --with-colons /tmp/cs.key \
            | awk -F: '/^fpr/ {print $10; exit}')"; \
    [ "$fpr" = "${CROWDSEC_GPG_FINGERPRINT}" ] \
        || { echo "FATAL: CrowdSec GPG fingerprint mismatch ($fpr)" >&2; exit 1; }; \
    install -d /usr/share/keyrings; \
    gpg --dearmor < /tmp/cs.key > /usr/share/keyrings/crowdsec.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ ${CROWDSEC_DEBIAN_RELEASE} main" \
        > /etc/apt/sources.list.d/crowdsec.list; \
    apt-get update; \
    \
    PKG="crowdsec-firewall-bouncer-${CS_FW_BOUNCER_FLAVOR}"; \
    mkdir -p /tmp/deb; cd /tmp/deb; \
    if [ -n "${CS_FW_BOUNCER_VERSION}" ]; then \
        apt-get download "${PKG}=${CS_FW_BOUNCER_VERSION}*"; \
    else \
        apt-get download "${PKG}"; \
    fi; \
    mkdir -p /tmp/bouncer; \
    dpkg-deb -x "$(ls ${PKG}_*.deb)" /tmp/bouncer; \
    \
    # The .deb installs /usr/bin/crowdsec-firewall-bouncer (static Go
    # binary) + a default .yaml. Put the binary on PATH and keep the
    # .deb's default config as a standalone fallback — the stack
    # bind-mounts its own crowdsec_firewall-bouncer.yaml over this path,
    # but a sane default lets the image run without compose too.
    BIN=/tmp/bouncer/usr/bin/crowdsec-firewall-bouncer; \
    [ -x "$BIN" ] \
        || { echo "FATAL: crowdsec-firewall-bouncer binary missing from .deb" >&2; exit 1; }; \
    head -c4 "$BIN" | grep -q ELF \
        || { echo "FATAL: crowdsec-firewall-bouncer is not an ELF binary" >&2; exit 1; }; \
    install -m755 "$BIN" /usr/local/bin/crowdsec-firewall-bouncer; \
    DEFCFG="$(find /tmp/bouncer -name 'crowdsec-firewall-bouncer.yaml' -print -quit)"; \
    [ -n "$DEFCFG" ] \
        || { echo "FATAL: default crowdsec-firewall-bouncer.yaml missing from .deb" >&2; exit 1; }; \
    install -D -m644 "$DEFCFG" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml; \
    \
    # Build-time smoke test (fail-loud, like the nginx image's `nginx -t`
    # guard): `-V` execs the binary and prints the version. Under buildx
    # this runs the TARGET arch via QEMU, so it also proves the
    # amd64/arm64 binary is the right architecture and not corrupt.
    crowdsec-firewall-bouncer -V; \
    \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/* /tmp/deb /tmp/bouncer /tmp/cs.key \
           /etc/apt/sources.list.d/crowdsec.list /usr/share/keyrings/crowdsec.gpg

# One process, no systemd/s6. network_mode: host + NET_ADMIN
# (set by docker-compose.yml) let it rewrite the host's iptables. The
# config path matches the stack's bind mount; override CMD if you bind
# the config somewhere else.
ENTRYPOINT ["crowdsec-firewall-bouncer"]
CMD ["-c", "/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"]
