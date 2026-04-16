#!/usr/bin/env sh
# layer5-vos/kernel/layout.sh
# Initialises the vOS kernel layout — directory tree, version info, proc mounts.
# This is the first script run when vOS starts inside the vCloud.
# Idempotent.
set -eu

log() { printf '[vos:kernel] %s\n' "$*"; }

VOS_ROOT="/vos"
VOS_VERSION="1.0.0"

# ── Create vOS filesystem skeleton ───────────────────────────────────────────
for d in \
    "${VOS_ROOT}/bin" \
    "${VOS_ROOT}/sbin" \
    "${VOS_ROOT}/etc" \
    "${VOS_ROOT}/var/log" \
    "${VOS_ROOT}/var/run" \
    "${VOS_ROOT}/var/lib/pkg" \
    "${VOS_ROOT}/proc" \
    "${VOS_ROOT}/sys" \
    "${VOS_ROOT}/dev" \
    "${VOS_ROOT}/tmp" \
    "${VOS_ROOT}/home" \
    "${VOS_ROOT}/mnt" \
    "${VOS_ROOT}/srv/api" \
    "${VOS_ROOT}/srv/web"; do
    mkdir -p "${d}"
done

log "vOS directory layout created at ${VOS_ROOT}"

# ── Write /vos/etc/vos-release ────────────────────────────────────────────────
if [ ! -f "${VOS_ROOT}/etc/vos-release" ]; then
    cat > "${VOS_ROOT}/etc/vos-release" <<EOF
VOS_NAME=vOS
VOS_VERSION=${VOS_VERSION}
VOS_ARCH=$(uname -m)
VOS_BUILD=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VOS_ROOT=${VOS_ROOT}
EOF
    log "vOS release file written."
fi

# ── Bind-mount /proc and /sys into vOS (best-effort) ─────────────────────────
mount --bind /proc "${VOS_ROOT}/proc" 2>/dev/null && log "/proc bound" || true
mount --bind /sys  "${VOS_ROOT}/sys"  2>/dev/null && log "/sys bound"  || true
mount --bind /dev  "${VOS_ROOT}/dev"  2>/dev/null && log "/dev bound"  || true

# ── vOS init marker ───────────────────────────────────────────────────────────
echo "${VOS_VERSION}" > "${VOS_ROOT}/etc/vos-version"
log "vOS kernel layout initialised (version ${VOS_VERSION})."
