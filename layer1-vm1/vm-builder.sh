#!/usr/bin/env sh
# layer1-vm1/vm-builder.sh
# Low-level QEMU VM creation helper used by build-vm2.sh.
# Creates a qcow2 disk, downloads a base ISO, and assembles QEMU launch args.
# Idempotent — skips steps that are already done.
#
# Required env vars (set by build-vm2.sh):
#   VM_NAME, VM_CPUS, VM_RAM_MB, VM_DISK_GB, VM_SSH_PORT, VM_DIR
#   VM_BASE_ISO_URL, QEMU_BIN, ACCEL_ARG, QEMU_MACHINE_ARGS
set -eu

log() { printf '[vm-builder:%s] %s\n' "${VM_NAME:-?}" "$*"; }

: "${VM_NAME:?}"
: "${VM_CPUS:?}"
: "${VM_RAM_MB:?}"
: "${VM_DISK_GB:?}"
: "${VM_SSH_PORT:?}"
: "${VM_DIR:?}"
: "${VM_BASE_ISO_URL:?}"
: "${QEMU_BIN:?}"

DISK_FILE="${VM_DIR}/${VM_NAME}.qcow2"
ISO_FILE="${VM_DIR}/base.iso"
LOG_FILE="${VM_DIR}/${VM_NAME}.log"
PID_FILE="${VM_DIR}/${VM_NAME}.pid"

mkdir -p "${VM_DIR}"

# ── Download base ISO (idempotent) ────────────────────────────────────────────
if [ ! -f "${ISO_FILE}" ]; then
    log "Downloading base ISO …"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ISO_FILE}" "${VM_BASE_ISO_URL}"
    else
        curl -fsSL -o "${ISO_FILE}" "${VM_BASE_ISO_URL}"
    fi
else
    log "ISO already present."
fi

# ── Create disk image (idempotent) ────────────────────────────────────────────
if [ ! -f "${DISK_FILE}" ]; then
    log "Creating disk: ${VM_DISK_GB}G → ${DISK_FILE}"
    qemu-img create -f qcow2 "${DISK_FILE}" "${VM_DISK_GB}G"
else
    log "Disk already exists."
fi

# ── Build and execute QEMU command ────────────────────────────────────────────
log "Launching ${VM_NAME} (SSH :${VM_SSH_PORT}) …"

# shellcheck disable=SC2086
"${QEMU_BIN}" \
    ${QEMU_MACHINE_ARGS:-} \
    ${ACCEL_ARG:-} \
    -smp "${VM_CPUS}" \
    -m "${VM_RAM_MB}M" \
    -drive "file=${DISK_FILE},format=qcow2,if=virtio" \
    -drive "file=${ISO_FILE},media=cdrom,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -virtfs "local,path=${VM_SCRIPTS_PATH:-/opt/vps-chain},mount_tag=host_scripts,security_model=none,id=scripts" \
    -serial "file:${LOG_FILE}" \
    -display none &

echo $! > "${PID_FILE}"
log "PID $(cat "${PID_FILE}") saved to ${PID_FILE}"
log "Console log: ${LOG_FILE}"
