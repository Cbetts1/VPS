#!/usr/bin/env sh
# layer2-vm2/validate-env.sh
# Validates that VM₂'s environment meets minimum requirements before a rebuild.
# Exits 0 on success, 1 on failure.
# Idempotent — read-only checks.
set -eu

log()  { printf '[validate-env] %s\n' "$*"; }
pass() { printf '[validate-env] ✔  %s\n' "$*"; }
fail() { printf '[validate-env] ✘  %s\n' "$*" >&2; }

ERRORS=0

# ── CPU count ─────────────────────────────────────────────────────────────────
CPUS="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
if [ "${CPUS}" -ge 1 ]; then
    pass "CPUs available: ${CPUS}"
else
    fail "No CPUs detected"
    ERRORS=$(( ERRORS + 1 ))
fi

# ── Available RAM ─────────────────────────────────────────────────────────────
RAM_MB="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
MIN_RAM=128
if [ "${RAM_MB}" -ge "${MIN_RAM}" ]; then
    pass "Available RAM: ${RAM_MB}MB"
else
    fail "Available RAM ${RAM_MB}MB < minimum ${MIN_RAM}MB"
    ERRORS=$(( ERRORS + 1 ))
fi

# ── Disk space ────────────────────────────────────────────────────────────────
FREE_GB="$(df -k / 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
MIN_DISK_GB=1
if [ "${FREE_GB}" -ge "${MIN_DISK_GB}" ]; then
    pass "Free disk: ${FREE_GB}GB"
else
    fail "Free disk ${FREE_GB}GB < minimum ${MIN_DISK_GB}GB"
    ERRORS=$(( ERRORS + 1 ))
fi

# ── QEMU availability ─────────────────────────────────────────────────────────
QEMU_FOUND="false"
for q in qemu-system-x86_64 qemu-system-aarch64 qemu-system-arm; do
    if command -v "${q}" >/dev/null 2>&1; then
        QEMU_FOUND="true"
        pass "QEMU found: ${q}"
        break
    fi
done
if [ "${QEMU_FOUND}" = "false" ]; then
    fail "No QEMU binary found in PATH"
    ERRORS=$(( ERRORS + 1 ))
fi

# ── qemu-img availability ─────────────────────────────────────────────────────
if command -v qemu-img >/dev/null 2>&1; then
    pass "qemu-img found"
else
    fail "qemu-img not found"
    ERRORS=$(( ERRORS + 1 ))
fi

# ── Network connectivity (best-effort) ────────────────────────────────────────
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    pass "Network reachable"
else
    log "WARNING: Network not reachable (continuing anyway)"
fi

# ── Version file ──────────────────────────────────────────────────────────────
if [ -f /etc/vm2-version ]; then
    VERSION="$(cat /etc/vm2-version)"
    pass "VM₂ version: ${VERSION}"
else
    log "NOTE: /etc/vm2-version not found — first run assumed"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [ "${ERRORS}" -eq 0 ]; then
    log "All checks passed."
    exit 0
else
    log "FAILED with ${ERRORS} error(s)."
    exit 1
fi
