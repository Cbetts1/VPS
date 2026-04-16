#!/usr/bin/env sh
# layer0-phone/build-vm1.sh
# Creates and launches VM₁ on the phone host using QEMU.
# Sources /tmp/host-caps.env produced by detect-host.sh.
# Idempotent — if the disk image already exists it is reused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPS_FILE="/tmp/host-caps.env"
VM1_DIR="/tmp/vm1"
VM1_DISK="${VM1_DIR}/vm1.qcow2"
VM1_SEED="${VM1_DIR}/seed.iso"
VM1_SSH_PORT=10022
VM1_LOG="${VM1_DIR}/vm1.log"

log() { printf '[build-vm1] %s\n' "$*"; }

# ── Ensure capabilities are available ─────────────────────────────────────────
if [ ! -f "${CAPS_FILE}" ]; then
    log "Running detect-host.sh first …"
    sh "${SCRIPT_DIR}/detect-host.sh"
fi
# shellcheck source=/dev/null
. "${CAPS_FILE}"

# ── Alpine Linux minimal image URL (multi-arch) ───────────────────────────────
ALPINE_VERSION="3.19.1"
case "${ARCH}" in
    aarch64|arm64)
        ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-${ALPINE_VERSION}-aarch64.iso"
        QEMU_MACHINE="-machine virt -cpu cortex-a57"
        BIOS_ARGS="-bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        ;;
    armv7l|armhf)
        ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/armhf/alpine-virt-${ALPINE_VERSION}-armhf.iso"
        QEMU_MACHINE="-machine virt -cpu cortex-a15"
        BIOS_ARGS=""
        ;;
    *)
        ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso"
        QEMU_MACHINE="-machine q35 -cpu host"
        BIOS_ARGS=""
        ;;
esac

# ── Directories ───────────────────────────────────────────────────────────────
mkdir -p "${VM1_DIR}"

# ── Download Alpine ISO (idempotent) ──────────────────────────────────────────
ALPINE_ISO="${VM1_DIR}/alpine.iso"
if [ ! -f "${ALPINE_ISO}" ]; then
    log "Downloading Alpine Linux ISO …"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ALPINE_ISO}" "${ALPINE_URL}"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "${ALPINE_ISO}" "${ALPINE_URL}"
    else
        log "ERROR: wget or curl required"
        exit 1
    fi
else
    log "Alpine ISO already present, skipping download."
fi

# ── Create disk image (idempotent) ────────────────────────────────────────────
if [ ! -f "${VM1_DISK}" ]; then
    log "Creating VM₁ disk: ${VM1_DISK_GB}G"
    qemu-img create -f qcow2 "${VM1_DISK}" "${VM1_DISK_GB}G"
else
    log "VM₁ disk already exists, reusing."
fi

# ── Build cloud-init seed ISO ─────────────────────────────────────────────────
log "Building cloud-init seed ISO …"
SEED_DIR="${VM1_DIR}/seed"
mkdir -p "${SEED_DIR}"

# Copy cloud-init templates from repo
cp "${REPO_ROOT}/layer1-vm1/cloud-init/user-data" "${SEED_DIR}/user-data"
cp "${REPO_ROOT}/layer1-vm1/cloud-init/meta-data" "${SEED_DIR}/meta-data"

if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "${VM1_SEED}" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -output "${VM1_SEED}" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -output "${VM1_SEED}" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
else
    log "WARNING: No ISO tool found (genisoimage/mkisofs/xorriso). Cloud-init seed skipped."
    VM1_SEED=""
fi

# ── KVM acceleration flag ─────────────────────────────────────────────────────
if [ "${KVM_AVAILABLE}" = "true" ]; then
    ACCEL_ARG="-enable-kvm"
else
    ACCEL_ARG=""
fi

# ── Build SEED drive arg ──────────────────────────────────────────────────────
if [ -n "${VM1_SEED}" ] && [ -f "${VM1_SEED}" ]; then
    SEED_ARG="-drive file=${VM1_SEED},media=cdrom,readonly=on"
else
    SEED_ARG=""
fi

# ── Copy VM₁ scripts into the disk (via a temporary overlay) ─────────────────
# Scripts are embedded as a virtfs share at /mnt/host-scripts inside the VM
SCRIPTS_ARG="-virtfs local,path=${REPO_ROOT}/layer1-vm1,mount_tag=host_scripts,security_model=none,id=scripts"

# ── Launch VM₁ ────────────────────────────────────────────────────────────────
log "Launching VM₁  (SSH will be available on localhost:${VM1_SSH_PORT}) …"
log "Log: ${VM1_LOG}"

# shellcheck disable=SC2086
nohup "${QEMU_BIN}" \
    ${QEMU_MACHINE} \
    ${ACCEL_ARG} \
    -smp "${VM1_CPUS}" \
    -m "${VM1_RAM_MB}M" \
    -drive "file=${VM1_DISK},format=qcow2,if=virtio" \
    -drive "file=${ALPINE_ISO},media=cdrom,readonly=on" \
    ${SEED_ARG} \
    ${BIOS_ARGS} \
    ${SCRIPTS_ARG} \
    -netdev "user,id=net0,hostfwd=tcp::${VM1_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -serial file:"${VM1_LOG}" \
    -display none \
    -daemonize 2>/dev/null || {
        log "daemonize not supported — starting in background via nohup"
        # Remove -daemonize and background manually
        "${QEMU_BIN}" \
            ${QEMU_MACHINE} \
            ${ACCEL_ARG} \
            -smp "${VM1_CPUS}" \
            -m "${VM1_RAM_MB}M" \
            -drive "file=${VM1_DISK},format=qcow2,if=virtio" \
            -drive "file=${ALPINE_ISO},media=cdrom,readonly=on" \
            ${SEED_ARG} \
            ${BIOS_ARGS} \
            ${SCRIPTS_ARG} \
            -netdev "user,id=net0,hostfwd=tcp::${VM1_SSH_PORT}-:22" \
            -device "virtio-net-pci,netdev=net0" \
            -serial file:"${VM1_LOG}" \
            -display none &
    }

log "VM₁ started. PID file: ${VM1_DIR}/vm1.pid"
log "Wait ~60s then: ssh -p ${VM1_SSH_PORT} root@localhost"
log "Inside VM₁ run: sh /mnt/host-scripts/build-vm2.sh"
