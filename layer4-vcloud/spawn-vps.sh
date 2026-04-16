#!/usr/bin/env sh
# layer4-vcloud/spawn-vps.sh
# Spawns an additional VPS instance inside the vCloud layer.
# Each new VPS is a QEMU VM on the br-vcloud bridge.
# Usage: sh spawn-vps.sh <vps_name> [cpus] [ram_mb] [disk_gb]
# Idempotent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VPS_REGISTRY="/vps/vcloud/vps-registry.db"
VCPU_CONF="/vps/config/vcpu.conf"

log() { printf '[vcloud:spawn-vps] %s\n' "$*"; }

VPS_NAME="${1:?Usage: spawn-vps.sh <name> [cpus] [ram_mb] [disk_gb]}"
VPS_CPUS="${2:-2}"
VPS_RAM="${3:-1024}"
VPS_DISK="${4:-8}"

mkdir -p /vps/vcloud
touch "${VPS_REGISTRY}"

if grep -q "^${VPS_NAME}:" "${VPS_REGISTRY}" 2>/dev/null; then
    log "VPS '${VPS_NAME}' already exists."
    exit 0
fi

[ -f "${VCPU_CONF}" ] && . "${VCPU_CONF}" || true
QEMU_BIN="${VCPU_QEMU_BIN:-$(command -v qemu-system-x86_64 2>/dev/null || echo '')}"
ACCEL="${VCPU_ACCEL_ARGS:-}"

ALPINE_VERSION="3.19.1"
ARCH="$(uname -m)"
case "${ARCH}" in
    aarch64|arm64) ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-${ALPINE_VERSION}-aarch64.iso" ;;
    *)             ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso" ;;
esac

VPS_DIR="/vps/vcloud/vps-${VPS_NAME}"
mkdir -p "${VPS_DIR}"

# Download ISO (shared across spawned VPS instances)
ISO_FILE="/vps/vcloud/alpine-base.iso"
if [ ! -f "${ISO_FILE}" ]; then
    log "Downloading Alpine ISO …"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ISO_FILE}" "${ISO_URL}"
    else
        curl -fsSL -o "${ISO_FILE}" "${ISO_URL}"
    fi
fi

DISK="${VPS_DIR}/${VPS_NAME}.qcow2"
if [ ! -f "${DISK}" ]; then
    qemu-img create -f qcow2 "${DISK}" "${VPS_DISK}G" >/dev/null
    log "Disk created: ${DISK}"
fi

# Assign ports
LAST_ID="$(wc -l < "${VPS_REGISTRY}")"
SSH_PORT=$(( 12000 + LAST_ID ))
API_PORT=$(( 12100 + LAST_ID ))
WEB_PORT=$(( 12200 + LAST_ID ))

# Cloud-init seed
SEED_DIR="${VPS_DIR}/seed"
mkdir -p "${SEED_DIR}"
cat > "${SEED_DIR}/user-data" <<USERDATA
#cloud-config
hostname: ${VPS_NAME}
runcmd:
  - mkdir -p /mnt/host-scripts
  - mount -t 9p -o trans=virtio,version=9p2000.L host_scripts /mnt/host-scripts || true
  - sh /mnt/host-scripts/layer3-vps/vhost/boot-scripts/boot.sh
USERDATA
echo "instance-id: ${VPS_NAME}" > "${SEED_DIR}/meta-data"

SEED_ISO="${VPS_DIR}/seed.iso"
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
    SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on"
else
    SEED_ARG=""
fi

case "${ARCH}" in
    aarch64|arm64) QEMU_MACHINE="-machine virt -cpu cortex-a57" ;;
    *)             QEMU_MACHINE="-machine q35" ;;
esac

LOG_FILE="${VPS_DIR}/${VPS_NAME}.log"
PID_FILE="${VPS_DIR}/${VPS_NAME}.pid"

# shellcheck disable=SC2086
"${QEMU_BIN}" \
    ${QEMU_MACHINE} \
    ${ACCEL} \
    -smp "${VPS_CPUS}" \
    -m "${VPS_RAM}M" \
    -drive "file=${DISK},format=qcow2,if=virtio" \
    -drive "file=${ISO_FILE},media=cdrom,readonly=on" \
    ${SEED_ARG} \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${API_PORT}-:8080,hostfwd=tcp::${WEB_PORT}-:80" \
    -device "virtio-net-pci,netdev=net0" \
    -netdev "tap,id=net1,br=br-vcloud,helper=/usr/lib/qemu/qemu-bridge-helper" \
    -device "virtio-net-pci,netdev=net1" \
    -virtfs "local,path=${REPO_ROOT},mount_tag=host_scripts,security_model=none,id=scripts" \
    -serial "file:${LOG_FILE}" \
    -display none &

echo $! > "${PID_FILE}"

printf '%s:%s:%s:%s:%s:%s\n' "${VPS_NAME}" "${VPS_CPUS}" "${VPS_RAM}" "${VPS_DISK}" \
    "${SSH_PORT}:${API_PORT}:${WEB_PORT}" "$(cat "${PID_FILE}")" >> "${VPS_REGISTRY}"

log "VPS '${VPS_NAME}' spawned:"
log "  SSH  :${SSH_PORT}"
log "  API  :${API_PORT}"
log "  WEB  :${WEB_PORT}"
log "  PID  :$(cat "${PID_FILE}")"
log "  Log  :${LOG_FILE}"
