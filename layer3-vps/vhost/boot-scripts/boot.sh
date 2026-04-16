#!/usr/bin/env sh
# layer3-vps/vhost/boot-scripts/boot.sh
# VPS boot sequence — runs once at startup via rc.local or cloud-init runcmd.
# Sources all vHost services in order.
# Idempotent.
set -eu

BOOT_LOG="/vps/logs/boot.log"
mkdir -p /vps/logs

log() { printf '[vhost:boot] %s\n' "$*" | tee -a "${BOOT_LOG}"; }

log "=== VPS Boot Sequence Started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

SCRIPTS_BASE="/mnt/host-scripts/layer3-vps"

# Run each layer in order; continue on non-fatal errors
for script in \
    "${SCRIPTS_BASE}/vhost/setup-filesystem.sh" \
    "${SCRIPTS_BASE}/vcpu/instruction-engine.sh" \
    "${SCRIPTS_BASE}/vos-kernel/services.sh" \
    "${SCRIPTS_BASE}/vos-kernel/package-manager.sh" \
    "${SCRIPTS_BASE}/vserver/apps.sh" \
    "${SCRIPTS_BASE}/vcloud-layer/networking.sh" \
    "${SCRIPTS_BASE}/expose/ssh-setup.sh" \
    "${SCRIPTS_BASE}/expose/api-endpoint.sh" \
    "${SCRIPTS_BASE}/expose/web-console.sh"; do
    if [ -f "${script}" ]; then
        log "Running: ${script}"
        sh "${script}" >> "${BOOT_LOG}" 2>&1 && log "OK: ${script}" || log "WARN: ${script} exited non-zero"
    else
        log "SKIP (not found): ${script}"
    fi
done

log "=== VPS Boot Sequence Complete ==="
