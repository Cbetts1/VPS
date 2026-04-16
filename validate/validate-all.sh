#!/usr/bin/env sh
# validate/validate-all.sh
# Validates every layer of the recursive virtualization chain.
# Also runs the doubling-spec logic test.
# Idempotent — safe to run repeatedly.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="${REPO_ROOT}/validate/validate-layer.sh"

log()  { printf '[validate-all] %s\n' "$*"; }
pass() { printf '[validate-all] ✔ %s\n' "$*"; }
fail() { printf '[validate-all] ✘ %s\n' "$*" >&2; }

TOTAL=0
FAILED=0

run_layer() {
    layer="$1"
    TOTAL=$(( TOTAL + 1 ))
    if sh "${VALIDATE}" "${layer}"; then
        pass "Layer ${layer}"
    else
        fail "Layer ${layer}"
        FAILED=$(( FAILED + 1 ))
    fi
}

log "=============================="
log " Recursive VPS Chain Validate"
log "=============================="

run_layer phone
run_layer vm1
run_layer vm2
run_layer vps
run_layer vcloud
run_layer vos

# ── Test doubling-spec logic ──────────────────────────────────────────────────
log ""
log "--- Doubling-spec logic test ---"
TOTAL=$(( TOTAL + 1 ))
SPEC_SCRIPT="${REPO_ROOT}/layer2-vm2/doubling-spec.sh"
if [ -f "${SPEC_SCRIPT}" ]; then
    SPEC_ERRORS=0
    for ver in 0 1 2 3 4 5; do
        sh "${SPEC_SCRIPT}" "${ver}" >/dev/null
        # shellcheck source=/dev/null
        . /tmp/vm2-specs.env
        log "  v${ver}: vCPU=${VM2_VCPUS}  vRAM=${VM2_VRAM_MB}MB  vDisk=${VM2_VDISK_GB}GB  cap=${VM2_AT_CAP}"

        # Verify caps are never exceeded
        if [ "${VM2_VCPUS}" -gt 16 ] || [ "${VM2_VRAM_MB}" -gt 16384 ] || [ "${VM2_VDISK_GB}" -gt 256 ]; then
            fail "  Version ${ver} exceeded spec caps!"
            SPEC_ERRORS=$(( SPEC_ERRORS + 1 ))
        fi
    done
    if [ "${SPEC_ERRORS}" -eq 0 ]; then
        pass "Doubling-spec logic — all caps respected"
    else
        fail "Doubling-spec logic — ${SPEC_ERRORS} cap violation(s)"
        FAILED=$(( FAILED + 1 ))
    fi
else
    fail "doubling-spec.sh not found"
    FAILED=$(( FAILED + 1 ))
fi

# ── version-counter self-test ─────────────────────────────────────────────────
log ""
log "--- Version-counter self-test ---"
TOTAL=$(( TOTAL + 1 ))
VER_SCRIPT="${REPO_ROOT}/layer2-vm2/version-counter.sh"
if [ -f "${VER_SCRIPT}" ]; then
    # Use a temp copy of the version file so we don't mutate /etc/vm2-version
    VERSION_FILE="/tmp/test-vm2-version" sh "${VER_SCRIPT}" reset >/dev/null
    V0="$(VERSION_FILE="/tmp/test-vm2-version" sh "${VER_SCRIPT}" get)"
    V1="$(VERSION_FILE="/tmp/test-vm2-version" sh "${VER_SCRIPT}" bump)"
    V2="$(VERSION_FILE="/tmp/test-vm2-version" sh "${VER_SCRIPT}" bump)"
    if [ "${V0}" = "0" ] && [ "${V1}" = "1" ] && [ "${V2}" = "2" ]; then
        pass "Version-counter: reset=0 bump=1 bump=2 ✔"
    else
        fail "Version-counter: unexpected values v0=${V0} v1=${V1} v2=${V2}"
        FAILED=$(( FAILED + 1 ))
    fi
else
    fail "version-counter.sh not found"
    FAILED=$(( FAILED + 1 ))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "=============================="
log " Results: $((TOTAL - FAILED))/${TOTAL} passed"
log "=============================="

if [ "${FAILED}" -eq 0 ]; then
    log "ALL CHECKS PASSED"
    exit 0
else
    log "FAILED: ${FAILED} check(s)"
    exit 1
fi
