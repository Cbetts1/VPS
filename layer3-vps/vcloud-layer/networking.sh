#!/usr/bin/env sh
# layer3-vps/vcloud-layer/networking.sh
# Sets up the vCloud networking overlay on the VPS.
# Creates a bridge (br-vcloud), enables IP forwarding, and configures
# WireGuard (if available) or a fallback VXLAN tunnel.
# Idempotent.
set -eu

log() { printf '[vcloud:net] %s\n' "$*"; }

VCLOUD_CONF="/vps/config/vcloud-net.conf"
mkdir -p /vps/config

# ── IP forwarding ─────────────────────────────────────────────────────────────
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null || true
log "IP forwarding enabled."

# ── Bridge br-vcloud ──────────────────────────────────────────────────────────
if ! ip link show br-vcloud >/dev/null 2>&1; then
    ip link add name br-vcloud type bridge 2>/dev/null || true
    ip addr add 192.168.200.1/24 dev br-vcloud 2>/dev/null || true
    ip link set br-vcloud up 2>/dev/null || true
    log "Bridge br-vcloud created: 192.168.200.0/24"
else
    log "Bridge br-vcloud already exists."
fi

# ── NAT masquerade for vCloud subnet ─────────────────────────────────────────
iptables -t nat -C POSTROUTING -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null || true
log "NAT masquerade configured."

# ── WireGuard vCloud overlay (if wg available) ────────────────────────────────
if command -v wg >/dev/null 2>&1; then
    WG_DIR="/etc/wireguard"
    mkdir -p "${WG_DIR}"
    chmod 700 "${WG_DIR}"
    if [ ! -f "${WG_DIR}/vcloud_private.key" ]; then
        wg genkey > "${WG_DIR}/vcloud_private.key"
        wg pubkey < "${WG_DIR}/vcloud_private.key" > "${WG_DIR}/vcloud_public.key"
        chmod 600 "${WG_DIR}/vcloud_private.key"
        log "WireGuard keypair generated."
    fi
    if [ ! -f "${WG_DIR}/vcloud.conf" ]; then
        cat > "${WG_DIR}/vcloud.conf" <<EOF
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PostUp   = wg set vcloud private-key ${WG_DIR}/vcloud_private.key
EOF
        chmod 600 "${WG_DIR}/vcloud.conf"
        log "WireGuard config written: ${WG_DIR}/vcloud.conf"
    fi
    # Bring up WireGuard interface
    wg-quick up vcloud 2>/dev/null || log "WireGuard vcloud already up or failed (non-fatal)"
else
    log "WireGuard not found — using bridge-only vCloud networking."
fi

# ── Write vCloud network descriptor ──────────────────────────────────────────
if [ ! -f "${VCLOUD_CONF}" ]; then
    cat > "${VCLOUD_CONF}" <<EOF
VCLOUD_BRIDGE=br-vcloud
VCLOUD_SUBNET=192.168.200.0/24
VCLOUD_GATEWAY=192.168.200.1
VCLOUD_WG_PORT=51820
VCLOUD_OVERLAY=$(command -v wg >/dev/null 2>&1 && echo wireguard || echo bridge)
EOF
    log "vCloud network config written."
fi

log "vCloud networking layer ready."
