#!/usr/bin/env sh
# layer4-vcloud/virtual-compute.sh
# Manages virtual compute pools — groups of vCloud nodes acting as one pool.
# Usage: sh virtual-compute.sh create <pool_name>
#        sh virtual-compute.sh add-node <pool_name> <node_name>
#        sh virtual-compute.sh list
#        sh virtual-compute.sh status <pool_name>
# Idempotent.
set -eu

COMPUTE_DIR="/vps/vcloud/compute"
COMPUTE_DB="${COMPUTE_DIR}/pools.db"
log() { printf '[vcloud:compute] %s\n' "$*"; }
mkdir -p "${COMPUTE_DIR}"
touch "${COMPUTE_DB}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    create)
        POOL_NAME="${1:?Usage: create <pool_name>}"
        if grep -q "^POOL:${POOL_NAME}:" "${COMPUTE_DB}" 2>/dev/null; then
            log "Compute pool '${POOL_NAME}' already exists."
            exit 0
        fi
        printf 'POOL:%s:0\n' "${POOL_NAME}" >> "${COMPUTE_DB}"
        log "Compute pool '${POOL_NAME}' created."
        ;;

    add-node)
        POOL_NAME="${1:?Usage: add-node <pool> <node>}"
        NODE_NAME="${2:?}"
        if ! grep -q "^POOL:${POOL_NAME}:" "${COMPUTE_DB}" 2>/dev/null; then
            log "Pool '${POOL_NAME}' not found. Create it first."
            exit 1
        fi
        if grep -q "^NODE:${POOL_NAME}:${NODE_NAME}" "${COMPUTE_DB}" 2>/dev/null; then
            log "Node '${NODE_NAME}' already in pool '${POOL_NAME}'."
            exit 0
        fi
        printf 'NODE:%s:%s\n' "${POOL_NAME}" "${NODE_NAME}" >> "${COMPUTE_DB}"
        # Update node count
        COUNT="$(grep -c "^NODE:${POOL_NAME}:" "${COMPUTE_DB}" || echo 0)"
        sed -i "s/^POOL:${POOL_NAME}:[0-9]*/POOL:${POOL_NAME}:${COUNT}/" "${COMPUTE_DB}" 2>/dev/null || true
        log "Node '${NODE_NAME}' added to pool '${POOL_NAME}' (total nodes: ${COUNT})."
        ;;

    list)
        if [ ! -s "${COMPUTE_DB}" ]; then
            log "No compute pools."
        else
            grep '^POOL:' "${COMPUTE_DB}" | awk -F: '{printf "Pool: %-15s  Nodes: %s\n", $2, $3}'
        fi
        ;;

    status)
        POOL_NAME="${1:?Usage: status <pool_name>}"
        log "=== Pool: ${POOL_NAME} ==="
        grep "^NODE:${POOL_NAME}:" "${COMPUTE_DB}" | awk -F: '{
            node=$3
            pidfile="/vps/vcloud/nodes/" node "/" node ".pid"
            cmd="test -f " pidfile " && kill -0 $(cat " pidfile ") 2>/dev/null && echo running || echo stopped"
            cmd | getline status
            printf "  Node: %-15s Status: %s\n", node, status
        }' || log "No nodes in pool."
        ;;

    *)
        printf 'Usage: %s create|add-node|list|status\n' "$0" >&2; exit 1
        ;;
esac
