#!/usr/bin/env sh
# layer0-phone/build-vm1.sh
# Creates and launches VM₁ on the phone host using QEMU.
# Sources host-caps.env (in $TMPDIR or /tmp) produced by detect-host.sh.
# Idempotent — if the disk image already exists it is reused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPS_FILE="${TMPDIR:-/tmp}/host-caps.env"
VM1_DIR="${TMPDIR:-/tmp}/vm1"
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
# Use QEMU_ARCH (guest arch) rather than host ARCH so the ISO and machine flags
# always match the selected QEMU binary (e.g. qemu-system-x86_64 on aarch64).
ALPINE_VERSION="3.19.1"
case "${QEMU_ARCH:-${ARCH}}" in
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
        # Use the native host CPU when KVM is available; fall back to a pure
        # software model (qemu64) for TCG cross-emulation.
        if [ "${KVM_AVAILABLE}" = "true" ]; then
            QEMU_MACHINE="-machine q35 -cpu host"
        else
            QEMU_MACHINE="-machine q35 -cpu qemu64"
        fi
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
elif command -v python3 >/dev/null 2>&1; then
    log "Using python3 fallback to create seed ISO …"
    python3 "${SCRIPT_DIR}/make-seed-iso.py" "${VM1_SEED}" "${SEED_DIR}"
else
    log "WARNING: No ISO tool found (genisoimage/mkisofs/xorriso/python3). Cloud-init seed skipped."
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

# ── Virtfs (9p host-scripts share) ───────────────────────────────────────────
# Only enable if the QEMU build supports virtfs; skip gracefully otherwise.
SCRIPTS_ARG=""
if [ "${VIRTFS_AVAILABLE:-false}" = "true" ]; then
    SCRIPTS_ARG="-virtfs local,path=${REPO_ROOT}/layer1-vm1,mount_tag=host_scripts,security_model=none,id=scripts"
else
    log "Virtfs not available — host-scripts share disabled (run build-vm2.sh manually inside VM₁)"
fi

# ── Stop any existing VM₁ that occupies the SSH port ─────────────────────────
# Re-using the port causes QEMU to exit immediately; kill the old instance first.
_port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | grep -q ":${VM1_SSH_PORT}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ":${VM1_SSH_PORT}[[:space:]]"
    else
        return 1  # cannot determine — assume free
    fi
}

if _port_in_use; then
    log "Port ${VM1_SSH_PORT} already bound — stopping existing VM₁ …"
    if [ -f "${VM1_DIR}/vm1.pid" ]; then
        OLD_PID="$(cat "${VM1_DIR}/vm1.pid")"
        kill "${OLD_PID}" 2>/dev/null || true
    else
        # Best-effort: kill any QEMU forwarding that port
        pkill -f "hostfwd=tcp::${VM1_SSH_PORT}" 2>/dev/null || true
    fi
    # Wait up to 5 s for the port to be released
    _waited=0
    while _port_in_use && [ "${_waited}" -lt 5 ]; do
        sleep 1
        _waited=$(( _waited + 1 ))
    done
fi

# ── Launch VM₁ ────────────────────────────────────────────────────────────────
log "Launching VM₁  (SSH will be available on localhost:${VM1_SSH_PORT}) …"
log "Log: ${VM1_LOG}"

# shellcheck disable=SC2086  # intentional word-splitting: QEMU_MACHINE/ACCEL_ARG/etc are multi-word flags
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
    -pidfile "${VM1_DIR}/vm1.pid" \
    -daemonize 2>/dev/null || {
        log "daemonize not supported — starting in background via nohup"
        # Remove -daemonize and background manually; capture PID ourselves
        # shellcheck disable=SC2086  # intentional word-splitting for QEMU flag variables
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
            -display none \
            >> "${VM1_LOG}" 2>&1 &
        echo $! > "${VM1_DIR}/vm1.pid"
    }

log "VM₁ started. PID file: ${VM1_DIR}/vm1.pid"

# ── Wait for VM₁ SSH to become ready ─────────────────────────────────────────
# TCG software emulation (no KVM) on a phone can take 10-20 minutes to fully
# boot Alpine and start sshd.  Poll the port instead of asking the user to
# guess how long to wait.
log "Polling for SSH on localhost:${VM1_SSH_PORT} (TCG may take 10-20 min) …"

_vm1_port_open() {
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 127.0.0.1 "${VM1_SSH_PORT}" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 - <<PYEOF 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(3)
sys.exit(0 if s.connect_ex(('127.0.0.1', ${VM1_SSH_PORT})) == 0 else 1)
PYEOF
    else
        # Last resort: attempt an SSH handshake and accept any non-reset result
        _r="$(ssh -o BatchMode=yes -o ConnectTimeout=4 \
            -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=0 \
            -p "${VM1_SSH_PORT}" root@localhost true 2>&1 || true)"
        case "${_r}" in
            *"Connection reset"*|*"Connection refused"*|*"connect: "*) return 1 ;;
            *) return 0 ;;
        esac
    fi
}

_max_wait=1200   # 20 minutes
_interval=15     # check every 15 seconds
_waited=0
_ready=false
while [ "${_waited}" -lt "${_max_wait}" ]; do
    if _vm1_port_open; then
        _ready=true
        break
    fi
    printf '.'
    sleep "${_interval}"
    _waited=$(( _waited + _interval ))
done
printf '\n'

if [ "${_ready}" = "true" ]; then
    log "VM₁ SSH is ready (waited ~${_waited}s)"
    log "Connect:  ssh -p ${VM1_SSH_PORT} -o StrictHostKeyChecking=no root@localhost  (password: vps2025)"
    if [ "${VIRTFS_AVAILABLE:-false}" = "true" ]; then
        log "Inside VM₁ run: sh /mnt/host-scripts/build-vm2.sh"
    else
        log "build-vm2.sh is running automatically inside VM₁ via cloud-init."
        log "Monitor: ssh -p ${VM1_SSH_PORT} -o StrictHostKeyChecking=no root@localhost 'tail -f /var/log/build-vm2.log'"
    fi
else
    log "WARNING: SSH did not become ready within ${_max_wait}s — VM₁ may still be booting."
    log "Check VM log:  tail -f ${VM1_LOG}"
    log "Once ready:    ssh -p ${VM1_SSH_PORT} -o StrictHostKeyChecking=no root@localhost  (password: vps2025)"
fi
