#!/usr/bin/env sh
# layer4-vcloud/virtual-storage.sh
# Manages virtual storage pools backed by qcow2 image files.
# Usage: sh virtual-storage.sh create <pool_name> <size_gb>
#        sh virtual-storage.sh list
#        sh virtual-storage.sh attach <pool_name> <node_name>
#        sh virtual-storage.sh destroy <pool_name>
# Idempotent.
set -eu

STORAGE_DIR="/vps/vcloud/storage"
STORAGE_DB="${STORAGE_DIR}/pools.db"
log() { printf '[vcloud:storage] %s\n' "$*"; }
mkdir -p "${STORAGE_DIR}"
touch "${STORAGE_DB}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    create)
        POOL_NAME="${1:?Usage: create <name> <size_gb>}"
        SIZE_GB="${2:-10}"

        if grep -q "^${POOL_NAME}:" "${STORAGE_DB}" 2>/dev/null; then
            log "Pool '${POOL_NAME}' already exists."
            exit 0
        fi

        POOL_FILE="${STORAGE_DIR}/${POOL_NAME}.qcow2"
        qemu-img create -f qcow2 "${POOL_FILE}" "${SIZE_GB}G" >/dev/null
        printf '%s:%s:%s:available\n' "${POOL_NAME}" "${POOL_FILE}" "${SIZE_GB}" >> "${STORAGE_DB}"
        log "Storage pool '${POOL_NAME}' created: ${SIZE_GB}G → ${POOL_FILE}"
        ;;

    list)
        if [ ! -s "${STORAGE_DB}" ]; then
            log "No storage pools."
        else
            printf '%-15s %-40s %-8s %-10s\n' NAME PATH SIZE_GB STATUS
            awk -F: '{printf "%-15s %-40s %-8s %-10s\n",$1,$2,$3,$4}' "${STORAGE_DB}"
        fi
        ;;

    attach)
        POOL_NAME="${1:?Usage: attach <pool> <node>}"
        NODE_NAME="${2:?}"
        POOL_FILE="$(grep "^${POOL_NAME}:" "${STORAGE_DB}" | cut -d: -f2)"
        if [ -z "${POOL_FILE}" ]; then
            log "Pool '${POOL_NAME}' not found."
            exit 1
        fi
        NODE_DIR="/vps/vcloud/nodes/${NODE_NAME}"
        if [ ! -d "${NODE_DIR}" ]; then
            log "Node '${NODE_NAME}' not found."
            exit 1
        fi
        # Append extra drive to node start script (idempotent marker)
        if ! grep -q "${POOL_FILE}" "${NODE_DIR}/start.sh" 2>/dev/null; then
            sed -i "s|-display none|-drive file=${POOL_FILE},format=qcow2,if=virtio \\\\\n    -display none|" \
                "${NODE_DIR}/start.sh" 2>/dev/null || true
            log "Pool '${POOL_NAME}' attached to node '${NODE_NAME}'."
        else
            log "Pool already attached."
        fi
        # Update status
        sed -i "s/^${POOL_NAME}:\(.*\):available/${POOL_NAME}:\1:attached:${NODE_NAME}/" "${STORAGE_DB}" 2>/dev/null || true
        ;;

    destroy)
        POOL_NAME="${1:?Usage: destroy <name>}"
        POOL_FILE="$(grep "^${POOL_NAME}:" "${STORAGE_DB}" | cut -d: -f2)"
        [ -n "${POOL_FILE}" ] && rm -f "${POOL_FILE}" && log "Deleted ${POOL_FILE}"
        sed -i "/^${POOL_NAME}:/d" "${STORAGE_DB}" 2>/dev/null || true
        log "Pool '${POOL_NAME}' destroyed."
        ;;

    *)
        printf 'Usage: %s create|list|attach|destroy\n' "$0" >&2; exit 1
        ;;
esac
