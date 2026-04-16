#!/usr/bin/env sh
# layer2-vm2/build-vps.sh
# VM₂'s final mission: produce a VPS instance.
# Called automatically by rebuild-self.sh when the spec cap is reached.
# Idempotent — skips already-built artifacts.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VPS_DIR="/tmp/vps"
VPS_SSH_PORT=10080
VPS_API_PORT=10081
VPS_WEB_PORT=10082

log() { printf '[build-vps] %s\n' "$*"; }

# ── Validate pre-conditions ───────────────────────────────────────────────────
log "Final validation before VPS build …"
sh "${SCRIPT_DIR}/validate-env.sh"

VERSION="$(sh "${SCRIPT_DIR}/version-counter.sh" get)"
log "Building VPS from VM₂ version ${VERSION}"

# ── Detect host environment ───────────────────────────────────────────────────
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
[ "${KVM_AVAILABLE:-false}" = "true" ] && ACCEL_ARG="-enable-kvm"

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

mkdir -p "${VPS_DIR}"

# ── Download ISO (idempotent) ─────────────────────────────────────────────────
ISO_FILE="${VPS_DIR}/base.iso"
if [ ! -f "${ISO_FILE}" ]; then
    log "Downloading Alpine ISO …"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ISO_FILE}" "${ISO_URL}"
    else
        curl -fsSL -o "${ISO_FILE}" "${ISO_URL}"
    fi
fi

# ── Create VPS disk (16 GB, final size) ──────────────────────────────────────
VPS_DISK="${VPS_DIR}/vps.qcow2"
if [ ! -f "${VPS_DISK}" ]; then
    log "Creating VPS disk: 16G"
    qemu-img create -f qcow2 "${VPS_DISK}" 16G
fi

# ── Build cloud-init for VPS ──────────────────────────────────────────────────
SEED_DIR="${VPS_DIR}/seed"
mkdir -p "${SEED_DIR}"

cat > "${SEED_DIR}/user-data" <<'USERDATA'
#cloud-config
hostname: vps01
packages:
  - openssh
  - nginx
  - python3
  - curl
  - wget
  - iptables
  - wireguard-tools
  - qemu-system-x86_64
  - qemu-img
  - git
package_update: true
runcmd:
  - mkdir -p /mnt/host-scripts
  - mount -t 9p -o trans=virtio,version=9p2000.L host_scripts /mnt/host-scripts || true
  - rc-update add sshd default && rc-service sshd start
  # Run all VPS layer setup scripts
  - sh /mnt/host-scripts/layer3-vps/vhost/setup-filesystem.sh
  - sh /mnt/host-scripts/layer3-vps/vcpu/instruction-engine.sh
  - sh /mnt/host-scripts/layer3-vps/vos-kernel/services.sh
  - sh /mnt/host-scripts/layer3-vps/vserver/apps.sh
  - sh /mnt/host-scripts/layer3-vps/vcloud-layer/networking.sh
  - sh /mnt/host-scripts/layer3-vps/expose/ssh-setup.sh
  - sh /mnt/host-scripts/layer3-vps/expose/api-endpoint.sh
  - sh /mnt/host-scripts/layer3-vps/expose/web-console.sh
  # Signal readiness
  - echo "VPS_READY=$(date -u +%s)" > /etc/vps-status
USERDATA

echo "instance-id: vps-01" > "${SEED_DIR}/meta-data"

SEED_ISO="${VPS_DIR}/seed.iso"
if [ ! -f "${SEED_ISO}" ]; then
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
            "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
        SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on"
    else
        SEED_ARG=""
    fi
else
    SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on"
fi

# ── Launch VPS ────────────────────────────────────────────────────────────────
log "Launching VPS …"
log "  SSH  :${VPS_SSH_PORT}"
log "  API  :${VPS_API_PORT}"
log "  WEB  :${VPS_WEB_PORT}"

VPS_LOG="${VPS_DIR}/vps.log"

# shellcheck disable=SC2086
"${QEMU_BIN}" \
    ${QEMU_MACHINE_ARGS} \
    ${ACCEL_ARG} \
    -smp 4 \
    -m 4096M \
    -drive "file=${VPS_DISK},format=qcow2,if=virtio" \
    -drive "file=${ISO_FILE},media=cdrom,readonly=on" \
    ${SEED_ARG} \
    -netdev "user,id=net0,\
hostfwd=tcp::${VPS_SSH_PORT}-:22,\
hostfwd=tcp::${VPS_API_PORT}-:8080,\
hostfwd=tcp::${VPS_WEB_PORT}-:80" \
    -device "virtio-net-pci,netdev=net0" \
    -virtfs "local,path=${REPO_ROOT},mount_tag=host_scripts,security_model=none,id=scripts" \
    -serial "file:${VPS_LOG}" \
    -display none &

VPS_PID=$!
echo "${VPS_PID}" > "${VPS_DIR}/vps.pid"

log "VPS PID: ${VPS_PID}"
log "Log: ${VPS_LOG}"
log "VM₂'s mission complete — VPS is running."
