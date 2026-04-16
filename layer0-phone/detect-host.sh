#!/usr/bin/env sh
# layer0-phone/detect-host.sh
# Detect host capabilities for running VM₁ from a phone (ARM/ARM64).
# Idempotent — safe to run multiple times.
# Outputs /tmp/host-caps.env which is sourced by build-vm1.sh.
set -eu

CAPS_FILE="${TMPDIR:-/tmp}/host-caps.env"

log() { printf '[detect-host] %s\n' "$*"; }

# ── Architecture ──────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
log "Architecture: ${ARCH}"

# ── KVM support ───────────────────────────────────────────────────────────────
KVM_AVAILABLE="false"
if [ -c /dev/kvm ]; then
    KVM_AVAILABLE="true"
    log "KVM device found: /dev/kvm"
else
    log "KVM not available — will use QEMU TCG (software emulation)"
fi

# ── CPU count and RAM ─────────────────────────────────────────────────────────
HOST_CPUS="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
HOST_RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)"
log "Host CPUs: ${HOST_CPUS}"
log "Host RAM MB: ${HOST_RAM_MB}"

# ── QEMU binary selection ─────────────────────────────────────────────────────
QEMU_BIN=""
for candidate in qemu-system-aarch64 qemu-system-arm qemu-system-x86_64; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        QEMU_BIN="${candidate}"
        break
    fi
done

if [ -z "${QEMU_BIN}" ]; then
    log "QEMU not found — attempting install"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq qemu-system-arm qemu-utils
        QEMU_BIN="qemu-system-aarch64"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache qemu-system-aarch64 qemu-img
        QEMU_BIN="qemu-system-aarch64"
    elif command -v pkg >/dev/null 2>&1; then
        pkg install -y qemu-utils
        QEMU_BIN="qemu-system-aarch64"
    else
        log "ERROR: Cannot install QEMU automatically. Please install qemu-system manually."
        exit 1
    fi
fi
log "QEMU binary: ${QEMU_BIN}"

# ── Derive safe VM₁ specs (half of host, min 1 CPU / 256 MB / 2 GB) ──────────
VM1_CPUS="$(( HOST_CPUS / 2 > 0 ? HOST_CPUS / 2 : 1 ))"
VM1_RAM_MB="$(( HOST_RAM_MB / 2 > 256 ? HOST_RAM_MB / 2 : 256 ))"
VM1_DISK_GB=4

# ── Write capability env file ─────────────────────────────────────────────────
cat > "${CAPS_FILE}" <<EOF
ARCH=${ARCH}
KVM_AVAILABLE=${KVM_AVAILABLE}
HOST_CPUS=${HOST_CPUS}
HOST_RAM_MB=${HOST_RAM_MB}
QEMU_BIN=${QEMU_BIN}
VM1_CPUS=${VM1_CPUS}
VM1_RAM_MB=${VM1_RAM_MB}
VM1_DISK_GB=${VM1_DISK_GB}
EOF

log "Capabilities written to ${CAPS_FILE}"
cat "${CAPS_FILE}"
