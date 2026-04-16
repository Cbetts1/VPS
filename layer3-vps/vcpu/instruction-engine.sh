#!/usr/bin/env sh
# layer3-vps/vcpu/instruction-engine.sh
# Configures the vCPU instruction engine layer.
# Uses QEMU's TCG or KVM as the underlying execution engine.
# Writes a vCPU descriptor that higher layers can query.
# Idempotent.
set -eu

log() { printf '[vcpu] %s\n' "$*"; }

VCPU_CONF="/vps/config/vcpu.conf"
mkdir -p /vps/config

# ── Detect execution engine ───────────────────────────────────────────────────
if [ -c /dev/kvm ]; then
    ENGINE="kvm"
    ACCEL="--enable-kvm"
    log "Execution engine: KVM (hardware acceleration)"
else
    ENGINE="tcg"
    ACCEL=""
    log "Execution engine: QEMU TCG (software)"
fi

ARCH="$(uname -m)"
CPUS="$(nproc)"
FREQ_MHZ="$(awk -F: '/cpu MHz/{printf "%d", $2; exit}' /proc/cpuinfo 2>/dev/null || echo 0)"

# ── Write vCPU descriptor ─────────────────────────────────────────────────────
if [ ! -f "${VCPU_CONF}" ]; then
    cat > "${VCPU_CONF}" <<EOF
VCPU_ENGINE=${ENGINE}
VCPU_ARCH=${ARCH}
VCPU_COUNT=${CPUS}
VCPU_FREQ_MHZ=${FREQ_MHZ}
VCPU_ACCEL_ARGS=${ACCEL}
VCPU_QEMU_BIN=$(command -v qemu-system-x86_64 2>/dev/null || command -v qemu-system-aarch64 2>/dev/null || echo '')
EOF
    log "vCPU descriptor written to ${VCPU_CONF}"
else
    log "vCPU descriptor already exists."
fi

# ── Verify QEMU is present ────────────────────────────────────────────────────
if grep -q '^VCPU_QEMU_BIN=$' "${VCPU_CONF}" 2>/dev/null; then
    log "WARNING: No QEMU binary found. Install qemu-system before launching nested VMs."
fi

log "vCPU instruction engine configured."
