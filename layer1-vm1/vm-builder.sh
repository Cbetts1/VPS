#!/usr/bin/env sh
# layer1-vm1/vm-builder.sh
# Low-level QEMU VM creation helper used by build-vm2.sh.
# Creates a qcow2 disk, downloads a base ISO, builds a cloud-init seed ISO,
# and assembles QEMU launch args.
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

# ── Build cloud-init seed so VM₂ boots fully automated ───────────────────────
SEED_DIR="${VM_DIR}/seed"
SEED_ISO="${VM_DIR}/${VM_NAME}-seed.iso"
mkdir -p "${SEED_DIR}"

if [ ! -f "${SEED_ISO}" ]; then
    # user-data: install packages, set root password, mount virtfs or git-clone,
    # then auto-run rebuild-self.sh so the doubling loop starts without manual SSH.
    cat > "${SEED_DIR}/user-data" <<USERDATA
#cloud-config
hostname: ${VM_NAME}
packages:
  - qemu-system-x86
  - qemu-img
  - qemu-system-aarch64
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

    printf 'instance-id: %s-instance\nlocal-hostname: %s\n' \
        "${VM_NAME}" "${VM_NAME}" > "${SEED_DIR}/meta-data"

    # Create seed ISO — try xorriso, then python3 (make-seed-iso.py in the repo)
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
            "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
        log "Seed ISO created (xorriso)."
    elif command -v python3 >/dev/null 2>&1; then
        # make-seed-iso.py lives in layer0-phone/ of the cloned repo
        MAKE_ISO="/opt/vps-chain/layer0-phone/make-seed-iso.py"
        if [ -f "${MAKE_ISO}" ]; then
            python3 "${MAKE_ISO}" "${SEED_ISO}" "${SEED_DIR}"
            log "Seed ISO created (python3 fallback)."
        else
            log "WARNING: make-seed-iso.py not found — seed ISO skipped."
        fi
    else
        log "WARNING: No ISO tool found — seed ISO skipped."
    fi
fi

# Attach seed ISO if it exists
SEED_ARG=""
if [ -f "${SEED_ISO}" ]; then
    SEED_ARG="-drive file=${SEED_ISO},media=cdrom,readonly=on,index=2"
fi

# ── Virtfs: share scripts into VM₂ (only if path exists) ─────────────────────
VIRTFS_ARG=""
_scripts_path="${VM_SCRIPTS_PATH:-/opt/vps-chain}"
if [ -d "${_scripts_path}" ]; then
    VIRTFS_ARG="-virtfs local,path=${_scripts_path},mount_tag=host_scripts,security_model=none,id=scripts"
    log "Virtfs enabled: ${_scripts_path} → host_scripts"
else
    log "VM_SCRIPTS_PATH not found (${_scripts_path}) — virtfs disabled; cloud-init git clone will be used."
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
    -drive "file=${ISO_FILE},media=cdrom,readonly=on,index=1" \
    ${SEED_ARG} \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    ${VIRTFS_ARG} \
    -serial "file:${LOG_FILE}" \
    -display none &

echo $! > "${PID_FILE}"
log "PID $(cat "${PID_FILE}") saved to ${PID_FILE}"
log "Console log: ${LOG_FILE}"
