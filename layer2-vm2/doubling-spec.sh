#!/usr/bin/env sh
# layer2-vm2/doubling-spec.sh
# Computes doubled VM specs given a version number.
# Doubles vCPU, vRAM, vDisk on each rebuild until the cap is reached.
#
# Usage: sh doubling-spec.sh <version>
#   Outputs a shell env file /tmp/vm2-specs.env with current specs.
#
# Caps (version ≥ 4 — stops doubling):
#   vCPU  max = 16
#   vRAM  max = 16384 MB  (16 GB)
#   vDisk max = 256 GB
#
# Starting specs (version = 0):
#   vCPU  = 1,   vRAM = 512 MB,  vDisk = 4 GB
set -eu

VERSION="${1:-0}"
SPECS_FILE="/tmp/vm2-specs.env"

# Starting values
BASE_CPUS=1
BASE_RAM_MB=512
BASE_DISK_GB=4

# Caps
MAX_CPUS=16
MAX_RAM_MB=16384
MAX_DISK_GB=256
MAX_VERSION=4       # stop doubling at (and beyond) this version

log() { printf '[doubling-spec] %s\n' "$*"; }

# Double function with cap
double_cap() {
    value="$1"
    max="$2"
    doubled=$(( value * 2 ))
    if [ "${doubled}" -gt "${max}" ]; then
        echo "${max}"
    else
        echo "${doubled}"
    fi
}

if [ "${VERSION}" -ge "${MAX_VERSION}" ]; then
    # Already at or past cap — use maximum values
    VCPUS="${MAX_CPUS}"
    VRAM_MB="${MAX_RAM_MB}"
    VDISK_GB="${MAX_DISK_GB}"
    log "Version ${VERSION} ≥ cap ${MAX_VERSION}: using maximum specs"
else
    # Start from base and double VERSION times
    VCPUS="${BASE_CPUS}"
    VRAM_MB="${BASE_RAM_MB}"
    VDISK_GB="${BASE_DISK_GB}"
    i=0
    while [ "${i}" -lt "${VERSION}" ]; do
        VCPUS="$(double_cap "${VCPUS}" "${MAX_CPUS}")"
        VRAM_MB="$(double_cap "${VRAM_MB}" "${MAX_RAM_MB}")"
        VDISK_GB="$(double_cap "${VDISK_GB}" "${MAX_DISK_GB}")"
        i=$(( i + 1 ))
    done
    log "Version ${VERSION}: vCPU=${VCPUS} vRAM=${VRAM_MB}MB vDisk=${VDISK_GB}GB"
fi

cat > "${SPECS_FILE}" <<EOF
VM2_VCPUS=${VCPUS}
VM2_VRAM_MB=${VRAM_MB}
VM2_VDISK_GB=${VDISK_GB}
VM2_VERSION=${VERSION}
VM2_AT_CAP=$([ "${VERSION}" -ge "${MAX_VERSION}" ] && echo true || echo false)
EOF
chmod 600 "${SPECS_FILE}"

log "Specs written to ${SPECS_FILE}"
cat "${SPECS_FILE}"
