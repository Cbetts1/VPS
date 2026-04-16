#!/usr/bin/env sh
# layer1-vm1/spec-evaluator.sh
# Reads /etc/vm1-specs.conf and prints current VM₁ specs.
# Used by other scripts to determine safe resource allocation for VM₂.
# Idempotent — read-only.
set -eu

SPECS_FILE="/etc/vm1-specs.conf"

log() { printf '[spec-evaluator] %s\n' "$*"; }

if [ ! -f "${SPECS_FILE}" ]; then
    log "WARNING: ${SPECS_FILE} not found — using defaults"
    VM1_VCPUS=1
    VM1_VRAM_MB=512
    VM1_VDISK_GB=4
else
    # shellcheck source=/dev/null
    . "${SPECS_FILE}"
fi

# Derive safe VM₂ starting specs: half of VM₁ allocation, minimums enforced
VM2_START_CPUS="$(( VM1_VCPUS > 1 ? VM1_VCPUS / 2 : 1 ))"
VM2_START_RAM_MB="$(( VM1_VRAM_MB / 2 > 256 ? VM1_VRAM_MB / 2 : 256 ))"
VM2_START_DISK_GB="$(( VM1_VDISK_GB / 2 > 2 ? VM1_VDISK_GB / 2 : 2 ))"

log "VM₁ specs:    vCPU=${VM1_VCPUS}  vRAM=${VM1_VRAM_MB}MB  vDisk=${VM1_VDISK_GB}GB"
log "VM₂ start:    vCPU=${VM2_START_CPUS}  vRAM=${VM2_START_RAM_MB}MB  vDisk=${VM2_START_DISK_GB}GB"

# Export for callers
cat > /tmp/vm2-init-specs.env <<EOF
VM2_START_CPUS=${VM2_START_CPUS}
VM2_START_RAM_MB=${VM2_START_RAM_MB}
VM2_START_DISK_GB=${VM2_START_DISK_GB}
EOF

log "Init specs written to /tmp/vm2-init-specs.env"
