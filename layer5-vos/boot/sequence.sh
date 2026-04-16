#!/usr/bin/env sh
# layer5-vos/boot/sequence.sh
# vOS boot sequence — runs all vOS layers in order.
# Designed to be called by the vCloud init process or cloud-init runcmd.
# Idempotent.
set -eu

BOOT_LOG="/vos/var/log/boot.log"
VOS_ROOT="/vos"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VOS_BASE="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '[vos:boot] %s\n' "$*" | tee -a "${BOOT_LOG}"; }
pass() { printf '[vos:boot] ✔ %s\n' "$*" | tee -a "${BOOT_LOG}"; }
warn() { printf '[vos:boot] ⚠ %s\n' "$*" | tee -a "${BOOT_LOG}"; }

mkdir -p "$(dirname "${BOOT_LOG}")"
log "=========================================="
log "vOS Boot Sequence  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "=========================================="

run_step() {
    label="$1"
    script="$2"
    if [ -f "${script}" ]; then
        log "Step: ${label}"
        sh "${script}" >> "${BOOT_LOG}" 2>&1 && pass "${label}" || warn "${label} exited non-zero (continuing)"
    else
        warn "Script not found: ${script}"
    fi
}

# ── Boot order ────────────────────────────────────────────────────────────────
run_step "Kernel Layout"      "${VOS_BASE}/kernel/layout.sh"
run_step "Virtual Filesystem" "${VOS_BASE}/filesystem/vfs.sh list"
run_step "Virtual Networking" "${VOS_BASE}/networking/vnet.sh list"
run_step "Package Manager"    "${VOS_BASE}/package-manager/vpkg.sh update"
run_step "Service Manager"    "${VOS_BASE}/service-manager/services.sh start"
run_step "API Gateway"        "${VOS_BASE}/api-gateway/gateway.sh start"

log "=========================================="
log "vOS boot complete."
log "=========================================="

# Write boot timestamp
echo "$(date -u +%s)" > "${VOS_ROOT}/var/run/boot.stamp"
