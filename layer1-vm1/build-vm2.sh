#!/usr/bin/env sh
# layer1-vm1/build-vm2.sh
# VM₁'s only job: create VM₂.
# Sources spec-evaluator.sh to get starting specs, then calls vm-builder.sh.
# Idempotent — skips steps already completed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM2_DIR="/tmp/vm2"
VM2_SSH_PORT=10023
VM2_LOG="${VM2_DIR}/vm2-builder.log"

log() { printf '[build-vm2] %s\n' "$*"; }

# ── Step 1: Self-update from repo ─────────────────────────────────────────────
log "Checking for updates …"
sh "${SCRIPT_DIR}/self-update.sh" || log "Self-update skipped (no network or git)"

# ── Step 2: Evaluate VM₁ specs to derive VM₂ starting specs ──────────────────
log "Evaluating specs …"
sh "${SCRIPT_DIR}/spec-evaluator.sh"
# shellcheck source=/dev/null
. /tmp/vm2-init-specs.env

# ── Step 3: Detect host QEMU/KVM environment ──────────────────────────────────
CAPS_FILE="/tmp/host-caps.env"
if [ -f "${CAPS_FILE}" ]; then
    . "${CAPS_FILE}"
else
    QEMU_BIN="$(command -v qemu-system-x86_64 || command -v qemu-system-aarch64)"
    KVM_AVAILABLE="false"
    ARCH="$(uname -m)"
fi

ACCEL_ARG=""
if [ "${KVM_AVAILABLE:-false}" = "true" ]; then
    ACCEL_ARG="-enable-kvm"
fi

case "${ARCH:-x86_64}" in
    aarch64|arm64) QEMU_MACHINE_ARGS="-machine virt -cpu cortex-a57" ;;
    armv7l|armhf)  QEMU_MACHINE_ARGS="-machine virt -cpu cortex-a15" ;;
    *)             QEMU_MACHINE_ARGS="-machine q35" ;;
esac

ALPINE_VERSION="3.19.1"
case "${ARCH:-x86_64}" in
    aarch64|arm64) ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-${ALPINE_VERSION}-aarch64.iso" ;;
    armv7l|armhf)  ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/armhf/alpine-virt-${ALPINE_VERSION}-armhf.iso" ;;
    *)             ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso" ;;
esac

# ── Step 4: Launch VM₂ via vm-builder ─────────────────────────────────────────
log "Creating VM₂ with vCPU=${VM2_START_CPUS} vRAM=${VM2_START_RAM_MB}MB vDisk=${VM2_START_DISK_GB}GB"

export VM_NAME="vm2"
export VM_CPUS="${VM2_START_CPUS}"
export VM_RAM_MB="${VM2_START_RAM_MB}"
export VM_DISK_GB="${VM2_START_DISK_GB}"
export VM_SSH_PORT="${VM2_SSH_PORT}"
export VM_DIR="${VM2_DIR}"
export VM_BASE_ISO_URL="${ISO_URL}"
export QEMU_BIN="${QEMU_BIN}"
export ACCEL_ARG="${ACCEL_ARG}"
export QEMU_MACHINE_ARGS="${QEMU_MACHINE_ARGS}"
export VM_SCRIPTS_PATH="/opt/vps-chain/layer2-vm2"

sh "${SCRIPT_DIR}/vm-builder.sh"

log "VM₂ is booting. SSH: ssh -p ${VM2_SSH_PORT} root@localhost"
log "Inside VM₂ run: sh /mnt/host-scripts/rebuild-self.sh"
log "VM₁'s mission complete."
