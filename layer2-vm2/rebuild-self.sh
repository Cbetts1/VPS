#!/usr/bin/env sh
# layer2-vm2/rebuild-self.sh
# VM₂'s self-rebuild loop:
#   1. Validate environment
#   2. Read current version
#   3. Compute doubled specs for next version
#   4. Create a new QEMU VM with those specs (the "next VM₂")
#   5. Bump version
#   6. Hand off to next VM₂ or proceed to build-vps.sh when cap is reached
#
# Idempotent — safe to run repeatedly; version file prevents re-doubling.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM2_REBUILD_DIR="/tmp/vm2-rebuild"

log() { printf '[rebuild-self] %s\n' "$*"; }

# ── Step 1: Validate current environment ──────────────────────────────────────
log "=== Validating environment ==="
sh "${SCRIPT_DIR}/validate-env.sh"

# ── Step 2: Read current version ──────────────────────────────────────────────
CURRENT_VERSION="$(sh "${SCRIPT_DIR}/version-counter.sh" get)"
log "Current version: ${CURRENT_VERSION}"

# ── Step 3: Check cap ─────────────────────────────────────────────────────────
MAX_VERSION=4
if [ "${CURRENT_VERSION}" -ge "${MAX_VERSION}" ]; then
    log "Version ${CURRENT_VERSION} ≥ cap ${MAX_VERSION}."
    log "Spec doubling complete. Proceeding to build VPS …"
    sh "${SCRIPT_DIR}/build-vps.sh"
    exit 0
fi

# ── Step 4: Compute next-version specs ────────────────────────────────────────
NEXT_VERSION=$(( CURRENT_VERSION + 1 ))
log "Computing specs for version ${NEXT_VERSION} …"
sh "${SCRIPT_DIR}/doubling-spec.sh" "${NEXT_VERSION}"
# shellcheck source=/dev/null
. /tmp/vm2-specs.env

log "Next specs: vCPU=${VM2_VCPUS}  vRAM=${VM2_VRAM_MB}MB  vDisk=${VM2_VDISK_GB}GB"

# ── Step 5: Detect host QEMU/KVM ──────────────────────────────────────────────
CAPS_FILE="/tmp/host-caps.env"
if [ -f "${CAPS_FILE}" ]; then
    # shellcheck source=/dev/null
    . "${CAPS_FILE}"
else
    QEMU_BIN="$(command -v qemu-system-x86_64 2>/dev/null \
             || command -v qemu-system-aarch64 2>/dev/null \
             || echo qemu-system-x86_64)"
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
    *)
        if [ "${KVM_AVAILABLE:-false}" = "true" ]; then
            QEMU_MACHINE_ARGS="-machine q35 -cpu host"
        else
            QEMU_MACHINE_ARGS="-machine q35 -cpu qemu64"
        fi
        ;;
esac

ALPINE_VERSION="3.19.1"
case "${ARCH:-x86_64}" in
    aarch64|arm64) ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-${ALPINE_VERSION}-aarch64.iso" ;;
    armv7l|armhf)  ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/armhf/alpine-virt-${ALPINE_VERSION}-armhf.iso" ;;
    *)             ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso" ;;
esac

# Port offset so each rebuilt VM₂ gets a unique SSH port
VM2_SSH_PORT=$(( 10023 + NEXT_VERSION ))
mkdir -p "${VM2_REBUILD_DIR}"

# ── Step 6: Launch next VM₂ with doubled specs (via vm-builder pattern) ───────
log "Launching VM₂ v${NEXT_VERSION} with doubled specs …"

ISO_FILE="${VM2_REBUILD_DIR}/base.iso"
DISK_FILE="${VM2_REBUILD_DIR}/vm2-v${NEXT_VERSION}.qcow2"
LOG_FILE="${VM2_REBUILD_DIR}/vm2-v${NEXT_VERSION}.log"

if [ ! -f "${ISO_FILE}" ]; then
    log "Downloading Alpine ISO …"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ISO_FILE}" "${ISO_URL}"
    else
        curl -fsSL -o "${ISO_FILE}" "${ISO_URL}"
    fi
fi

if [ ! -f "${DISK_FILE}" ]; then
    log "Creating disk: ${VM2_VDISK_GB}G"
    qemu-img create -f qcow2 "${DISK_FILE}" "${VM2_VDISK_GB}G"
fi

# Write version file onto disk via a cloud-init seed
SEED_DIR="${VM2_REBUILD_DIR}/seed-v${NEXT_VERSION}"
mkdir -p "${SEED_DIR}"
cat > "${SEED_DIR}/user-data" <<USERDATA
#cloud-config
hostname: vm2-v${NEXT_VERSION}
packages:
  - qemu-system-x86
  - qemu-img
  - openssh
  - git
  - xorriso
  - python3
package_update: true
chpasswd:
  list: |
    root:vps2025
  expire: false
ssh_pwauth: true
disable_root: false
runcmd:
  - echo "${NEXT_VERSION}" > /etc/vm2-version
  - rc-update add sshd default
  - rc-service sshd start
  - |
    mkdir -p /mnt/host-scripts
    if mount -t 9p -o trans=virtio,version=9p2000.L host_scripts /mnt/host-scripts 2>/dev/null; then
      REBUILD_SCRIPT=/mnt/host-scripts/rebuild-self.sh
    else
      apk add --no-cache git >/dev/null 2>&1 || true
      if [ ! -d /opt/vps-chain/.git ]; then
        git clone --depth=1 https://github.com/Cbetts1/VPS /opt/vps-chain 2>&1 | tee /var/log/git-clone.log || true
      fi
      REBUILD_SCRIPT=/opt/vps-chain/layer2-vm2/rebuild-self.sh
    fi
    if [ ! -f "\${REBUILD_SCRIPT}" ]; then
      echo "[cloud-init] ERROR: rebuild-self.sh not found at \${REBUILD_SCRIPT} — check /var/log/git-clone.log" >&2
      exit 1
    fi
    nohup sh "\${REBUILD_SCRIPT}" > /var/log/rebuild-self.log 2>&1 &
USERDATA
echo "instance-id: vm2-v${NEXT_VERSION}" > "${SEED_DIR}/meta-data"

SEED_ISO="${VM2_REBUILD_DIR}/seed-v${NEXT_VERSION}.iso"
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
    SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on"
else
    SEED_ARG=""
fi

SCRIPTS_PATH="${SCRIPT_DIR}"

# shellcheck disable=SC2086
"${QEMU_BIN}" \
    ${QEMU_MACHINE_ARGS} \
    ${ACCEL_ARG} \
    -smp "${VM2_VCPUS}" \
    -m "${VM2_VRAM_MB}M" \
    -drive "file=${DISK_FILE},format=qcow2,if=virtio" \
    -drive "file=${ISO_FILE},media=cdrom,readonly=on" \
    ${SEED_ARG} \
    -netdev "user,id=net0,hostfwd=tcp::${VM2_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -virtfs "local,path=${SCRIPTS_PATH},mount_tag=host_scripts,security_model=none,id=scripts" \
    -serial "file:${LOG_FILE}" \
    -display none &

log "VM₂ v${NEXT_VERSION} PID: $!"
log "SSH: ssh -p ${VM2_SSH_PORT} root@localhost"
log "Log: ${LOG_FILE}"

# ── Step 7: Bump version on current VM₂ ──────────────────────────────────────
sh "${SCRIPT_DIR}/version-counter.sh" bump
log "Rebuild cycle complete. Next VM₂ will continue from version ${NEXT_VERSION}."
