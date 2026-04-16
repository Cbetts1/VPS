#!/usr/bin/env sh
# layer2-vm2/build-vps.sh
# VM₂'s final mission: produce a VPS instance.
# Called automatically by rebuild-self.sh when the spec cap is reached.
# Idempotent — skips already-built artifacts.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VPS_DIR="/tmp/vps"
VPS_SSH_PORT=10080
VPS_API_PORT=10081
VPS_WEB_PORT=10082

log() { printf '[build-vps] %s\n' "$*"; }

# ── Ensure the full repo is available for sharing with the VPS ───────────────
# The virtfs share for VPS needs the complete repo (all layers).
# self-update.sh clones to /opt/vps-chain; if it is missing (e.g. we arrived
# here from a rebuilt VM₂ that didn't call build-vm2.sh), clone it now.
REPO_ROOT="/opt/vps-chain"
if [ ! -d "${REPO_ROOT}/.git" ]; then
    log "Cloning full repo to ${REPO_ROOT} …"
    apk add --no-cache git >/dev/null 2>&1 || true
    git clone --depth=1 https://github.com/Cbetts1/VPS "${REPO_ROOT}" 2>&1 | tee /var/log/git-clone-vps.log || true
    if [ ! -d "${REPO_ROOT}/layer3-vps" ]; then
        log "ERROR: Repo clone to ${REPO_ROOT} failed — check /var/log/git-clone-vps.log"
        exit 1
    fi
fi

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

# Note: 'qemu-system-x86_64' is not a valid Alpine apk package name;
# the correct package is 'qemu-system-x86' which provides the binary.
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
  - qemu-system-x86
  - qemu-img
  - git
package_update: true
chpasswd:
  list: |
    root:vps2025
  expire: false
ssh_pwauth: true
disable_root: false
runcmd:
  - rc-update add sshd default
  - rc-service sshd start
  # Mount virtfs repo share, or fall back to git clone
  - |
    mkdir -p /mnt/host-scripts
    if ! mount -t 9p -o trans=virtio,version=9p2000.L host_scripts /mnt/host-scripts 2>/dev/null; then
      apk add --no-cache git >/dev/null 2>&1 || true
      if [ ! -d /mnt/host-scripts/.git ]; then
        git clone --depth=1 https://github.com/Cbetts1/VPS /mnt/host-scripts 2>&1 | tee /var/log/git-clone.log || true
      fi
    fi
    if [ ! -d /mnt/host-scripts/layer3-vps ]; then
      echo "[cloud-init] ERROR: layer3-vps not found — check /var/log/git-clone.log" >&2
      exit 1
    fi
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
        SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on,index=2"
    elif command -v python3 >/dev/null 2>&1 && [ -f "${REPO_ROOT}/layer0-phone/make-seed-iso.py" ]; then
        python3 "${REPO_ROOT}/layer0-phone/make-seed-iso.py" "${SEED_ISO}" "${SEED_DIR}"
        SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on,index=2"
    else
        log "WARNING: No ISO tool — VPS seed skipped; cloud-init fallback will use git clone"
        SEED_ARG=""
    fi
else
    SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on,index=2"
fi

# ── Virtfs: share full repo into VPS (only if REPO_ROOT exists) ──────────────
VIRTFS_ARG=""
if [ -d "${REPO_ROOT}" ]; then
    VIRTFS_ARG="-virtfs local,path=${REPO_ROOT},mount_tag=host_scripts,security_model=none,id=scripts"
    log "Virtfs enabled: ${REPO_ROOT} → host_scripts"
else
    log "REPO_ROOT not found — VPS scripts will be git-cloned by cloud-init"
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
    -drive "file=${ISO_FILE},media=cdrom,readonly=on,index=1" \
    ${SEED_ARG} \
    -netdev "user,id=net0,\
hostfwd=tcp::${VPS_SSH_PORT}-:22,\
hostfwd=tcp::${VPS_API_PORT}-:8080,\
hostfwd=tcp::${VPS_WEB_PORT}-:80" \
    -device "virtio-net-pci,netdev=net0" \
    ${VIRTFS_ARG} \
    -serial "file:${VPS_LOG}" \
    -display none &

VPS_PID=$!
echo "${VPS_PID}" > "${VPS_DIR}/vps.pid"

log "VPS PID: ${VPS_PID}"
log "Log: ${VPS_LOG}"
log "VM₂'s mission complete — VPS is running."
