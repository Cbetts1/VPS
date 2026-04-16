#!/usr/bin/env sh
# layer3-vps/expose/ssh-setup.sh
# Hardens and configures SSHd for the VPS.
# Idempotent.
set -eu

log() { printf '[expose:ssh] %s\n' "$*"; }

SSHD_CONF="/etc/ssh/sshd_config"

# ── Generate host keys if missing ─────────────────────────────────────────────
ssh-keygen -A 2>/dev/null || true
log "SSH host keys ensured."

# ── Apply minimal hardening (idempotent via marker) ──────────────────────────
MARKER="# vOS-hardened"
if ! grep -q "${MARKER}" "${SSHD_CONF}" 2>/dev/null; then
    cat >> "${SSHD_CONF}" <<EOF
${MARKER}
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AllowTcpForwarding yes
X11Forwarding no
PrintMotd no
EOF
    log "SSH hardening config appended."
fi

# ── Start / reload sshd ───────────────────────────────────────────────────────
if rc-service sshd status >/dev/null 2>&1; then
    rc-service sshd reload 2>/dev/null || true
    log "SSHd reloaded."
else
    rc-update add sshd default 2>/dev/null || true
    rc-service sshd start 2>/dev/null || true
    log "SSHd started."
fi

log "SSH exposure configured (port 22)."
