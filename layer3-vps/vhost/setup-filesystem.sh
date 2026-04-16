#!/usr/bin/env sh
# layer3-vps/vhost/setup-filesystem.sh
# Configures the VPS root filesystem and persistent directories.
# Idempotent — creates directories only if absent.
set -eu

log() { printf '[vhost:fs] %s\n' "$*"; }

# ── Base directory layout ─────────────────────────────────────────────────────
for d in \
    /vps/data \
    /vps/logs \
    /vps/config \
    /vps/run \
    /vps/apps \
    /vps/vcloud \
    /vps/vos; do
    if [ ! -d "${d}" ]; then
        mkdir -p "${d}"
        log "Created ${d}"
    fi
done

# ── /etc/vps-release ─────────────────────────────────────────────────────────
if [ ! -f /etc/vps-release ]; then
    cat > /etc/vps-release <<'EOF'
VPS_NAME=vps01
VPS_VERSION=1.0.0
VPS_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    log "Created /etc/vps-release"
fi

# ── Swap (if not present and space allows) ────────────────────────────────────
if [ ! -f /vps/swapfile ]; then
    FREE_GB="$(df -k / | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    if [ "${FREE_GB}" -ge 2 ]; then
        log "Creating 1G swapfile …"
        dd if=/dev/zero of=/vps/swapfile bs=1M count=1024 status=none
        chmod 600 /vps/swapfile
        mkswap /vps/swapfile >/dev/null
        swapon /vps/swapfile || true
        log "Swap enabled."
    fi
fi

log "vHost filesystem setup complete."
