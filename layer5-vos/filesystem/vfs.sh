#!/usr/bin/env sh
# layer5-vos/filesystem/vfs.sh
# Virtual Filesystem manager for vOS.
# Mounts/unmounts virtual volumes (qcow2-backed loop mounts).
# Usage: sh vfs.sh mount <image.qcow2> <mountpoint>
#        sh vfs.sh umount <mountpoint>
#        sh vfs.sh list
# Idempotent.
set -eu

VFS_DB="/vos/var/lib/vfs.db"
log() { printf '[vos:vfs] %s\n' "$*"; }
mkdir -p /vos/var/lib
touch "${VFS_DB}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    mount)
        IMAGE="${1:?Usage: mount <image> <mountpoint>}"
        MOUNTPOINT="${2:?}"
        mkdir -p "${MOUNTPOINT}"

        if mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            log "${MOUNTPOINT} already mounted."
            exit 0
        fi

        # Use qemu-nbd to expose the qcow2 as a block device
        if command -v qemu-nbd >/dev/null 2>&1; then
            modprobe nbd max_part=8 2>/dev/null || true
            # Find a free nbd device
            NBD_DEV=""
            for n in /dev/nbd{0..15}; do
                if ! grep -q "${n}" "${VFS_DB}" 2>/dev/null; then
                    NBD_DEV="${n}"
                    break
                fi
            done
            if [ -z "${NBD_DEV}" ]; then
                log "No free nbd device."
                exit 1
            fi
            qemu-nbd --connect="${NBD_DEV}" "${IMAGE}"
            sleep 1
            mount "${NBD_DEV}" "${MOUNTPOINT}" 2>/dev/null || \
                mount "${NBD_DEV}p1" "${MOUNTPOINT}" 2>/dev/null || {
                    log "Mount failed — image may not be formatted"
                    qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true
                    exit 1
                }
            printf '%s:%s:%s\n' "${MOUNTPOINT}" "${IMAGE}" "${NBD_DEV}" >> "${VFS_DB}"
            log "Mounted ${IMAGE} → ${MOUNTPOINT} via ${NBD_DEV}"
        else
            log "qemu-nbd not available — using bind mount fallback"
            mount --bind "${IMAGE}" "${MOUNTPOINT}" 2>/dev/null || true
            printf '%s:%s:bind\n' "${MOUNTPOINT}" "${IMAGE}" >> "${VFS_DB}"
        fi
        ;;

    umount)
        MOUNTPOINT="${1:?Usage: umount <mountpoint>}"
        if mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            NBD_DEV="$(grep "^${MOUNTPOINT}:" "${VFS_DB}" | cut -d: -f3)"
            umount "${MOUNTPOINT}" 2>/dev/null || true
            if [ -n "${NBD_DEV}" ] && [ "${NBD_DEV}" != "bind" ]; then
                qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true
            fi
            sed -i "\\|^${MOUNTPOINT}:|d" "${VFS_DB}" 2>/dev/null || true
            log "Unmounted ${MOUNTPOINT}"
        else
            log "${MOUNTPOINT} is not mounted."
        fi
        ;;

    list)
        if [ ! -s "${VFS_DB}" ]; then
            log "No virtual filesystems mounted."
        else
            printf '%-30s %-40s %-10s\n' MOUNTPOINT IMAGE DEVICE
            awk -F: '{printf "%-30s %-40s %-10s\n",$1,$2,$3}' "${VFS_DB}"
        fi
        ;;

    *)
        printf 'Usage: %s mount|umount|list\n' "$0" >&2; exit 1
        ;;
esac
