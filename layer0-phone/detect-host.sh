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
        # Termux: install the QEMU system emulator matching the host architecture.
        # Package names use hyphens (e.g. qemu-system-aarch64); the installed
        # binary uses underscores (e.g. qemu-system-aarch64), so the re-probe
        # loop below will find it correctly.
        case "${ARCH}" in
            aarch64|arm64) pkg install -y qemu-system-aarch64 ;;
            armv7l|armhf)  pkg install -y qemu-system-arm ;;
            *)             pkg install -y qemu-system-x86-64-headless ;;
        esac
        # Also install xorriso so the cloud-init seed ISO can be created.
        pkg install -y xorriso 2>/dev/null || true
        # Re-probe after install
        for candidate in qemu-system-aarch64 qemu-system-arm qemu-system-x86_64; do
            if command -v "${candidate}" >/dev/null 2>&1; then
                QEMU_BIN="${candidate}"
                break
            fi
        done
        if [ -z "${QEMU_BIN}" ]; then
            log "ERROR: QEMU install succeeded but binary not found. Install qemu-system manually."
            exit 1
        fi
    else
        log "ERROR: Cannot install QEMU automatically. Please install qemu-system manually."
        exit 1
    fi
fi
log "QEMU binary: ${QEMU_BIN}"

# ── Derive the guest architecture from the selected QEMU binary ───────────────
# This may differ from ARCH when cross-emulating (e.g. qemu-system-x86_64 on
# an aarch64 host).  build-vm1.sh uses QEMU_ARCH — not ARCH — to choose the
# correct -machine type, CPU model, and Alpine ISO.
case "${QEMU_BIN}" in
    *aarch64*)    QEMU_ARCH="aarch64" ;;
    *-arm|*-armhf|*-arm-*) QEMU_ARCH="armv7l"  ;;
    *x86_64*)     QEMU_ARCH="x86_64"  ;;
    *)            QEMU_ARCH="${ARCH}"  ;;
esac
log "QEMU guest architecture: ${QEMU_ARCH}"

# ── Virtfs (9p / Plan-9 filesystem) support ───────────────────────────────────
# Check whether the selected QEMU binary understands -virtfs.  Not all Termux
# builds include the virtio-9p device; the result is written to the caps file
# so build-vm1.sh can skip the option gracefully when it is absent.
VIRTFS_AVAILABLE="false"
if "${QEMU_BIN}" -fsdev help 2>&1 | grep -q 'local\|security_model'; then
    VIRTFS_AVAILABLE="true"
    log "Virtfs (9p) support: available"
else
    log "Virtfs (9p) support: not available — host-scripts share will be skipped"
fi

# ── ISO creation tool detection ───────────────────────────────────────────────
HAS_ISO_TOOL="false"
for _isotool in genisoimage mkisofs xorriso; do
    if command -v "${_isotool}" >/dev/null 2>&1; then
        HAS_ISO_TOOL="true"
        log "ISO tool found: ${_isotool}"
        break
    fi
done
if [ "${HAS_ISO_TOOL}" = "false" ] && command -v python3 >/dev/null 2>&1; then
    log "No ISO tool found; python3 fallback will be used"
elif [ "${HAS_ISO_TOOL}" = "false" ]; then
    log "WARNING: No ISO tool and no python3 found — cloud-init seed will be skipped"
fi

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
QEMU_ARCH=${QEMU_ARCH}
VM1_CPUS=${VM1_CPUS}
VM1_RAM_MB=${VM1_RAM_MB}
VM1_DISK_GB=${VM1_DISK_GB}
VIRTFS_AVAILABLE=${VIRTFS_AVAILABLE}
HAS_ISO_TOOL=${HAS_ISO_TOOL}
EOF

log "Capabilities written to ${CAPS_FILE}"
cat "${CAPS_FILE}"
