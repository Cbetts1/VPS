#!/usr/bin/env sh
# layer4-vcloud/virtual-nodes.sh
# Manages vCloud virtual nodes.
# A node is a lightweight QEMU VM attached to the br-vcloud bridge.
# Usage: sh virtual-nodes.sh create <name> [cpus] [ram_mb] [disk_gb]
#        sh virtual-nodes.sh list
#        sh virtual-nodes.sh destroy <name>
# Idempotent: create is a no-op if the node already exists.
set -eu

NODES_DIR="/vps/vcloud/nodes"
NODES_DB="${NODES_DIR}/nodes.db"
VCPU_CONF="/vps/config/vcpu.conf"
VCLOUD_NET_CONF="/vps/config/vcloud-net.conf"

log() { printf '[vcloud:nodes] %s\n' "$*"; }

mkdir -p "${NODES_DIR}"
touch "${NODES_DB}"

# Source config files if present
[ -f "${VCPU_CONF}" ]       && . "${VCPU_CONF}"       || true
[ -f "${VCLOUD_NET_CONF}" ] && . "${VCLOUD_NET_CONF}" || true

QEMU_BIN="${VCPU_QEMU_BIN:-$(command -v qemu-system-x86_64 2>/dev/null || echo '')}"
ACCEL="${VCPU_ACCEL_ARGS:-}"
BRIDGE="${VCLOUD_BRIDGE:-br-vcloud}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    create)
        NODE_NAME="${1:?Usage: create <name> [cpus] [ram] [disk]}"
        NODE_CPUS="${2:-1}"
        NODE_RAM="${3:-256}"
        NODE_DISK="${4:-4}"

        if grep -q "^${NODE_NAME}:" "${NODES_DB}" 2>/dev/null; then
            log "Node '${NODE_NAME}' already exists."
            exit 0
        fi

        NODE_DIR="${NODES_DIR}/${NODE_NAME}"
        mkdir -p "${NODE_DIR}"

        # Allocate IP from 192.168.200.x pool
        LAST_IP="$(awk -F: '{print $2}' "${NODES_DB}" | sort -t. -k4 -n | tail -1 | cut -d/ -f1 | awk -F. '{print $4}')"
        LAST_IP="${LAST_IP:-1}"
        NODE_IP="192.168.200.$(( LAST_IP + 1 ))"

        # Create disk
        DISK="${NODE_DIR}/${NODE_NAME}.qcow2"
        if [ ! -f "${DISK}" ]; then
            qemu-img create -f qcow2 "${DISK}" "${NODE_DISK}G" >/dev/null
        fi

        SSH_PORT=$(( 11000 + LAST_IP + 1 ))

        # Write node start script
        cat > "${NODE_DIR}/start.sh" <<NODESTART
#!/usr/bin/env sh
# Auto-generated node start script for ${NODE_NAME}
set -eu
${QEMU_BIN} \\
    ${ACCEL} \\
    -smp ${NODE_CPUS} \\
    -m ${NODE_RAM}M \\
    -drive file=${DISK},format=qcow2,if=virtio \\
    -netdev tap,id=net0,br=${BRIDGE},helper=/usr/lib/qemu/qemu-bridge-helper \\
    -device virtio-net-pci,netdev=net0,mac=52:54:00:$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((LAST_IP+1))) \\
    -netdev user,id=net1,hostfwd=tcp::${SSH_PORT}-:22 \\
    -device virtio-net-pci,netdev=net1 \\
    -serial file:${NODE_DIR}/${NODE_NAME}.log \\
    -display none &
echo \$! > ${NODE_DIR}/${NODE_NAME}.pid
NODESTART
        chmod +x "${NODE_DIR}/start.sh"

        # Register in DB
        printf '%s:%s:%s:%s:%s:%s\n' \
            "${NODE_NAME}" "${NODE_IP}/24" "${NODE_CPUS}" "${NODE_RAM}" "${NODE_DISK}" "${SSH_PORT}" \
            >> "${NODES_DB}"

        log "Node '${NODE_NAME}' registered: IP=${NODE_IP} SSH=:${SSH_PORT}"
        log "Start with: sh ${NODE_DIR}/start.sh"
        ;;

    list)
        if [ ! -s "${NODES_DB}" ]; then
            log "No nodes registered."
        else
            printf '%-15s %-18s %-6s %-8s %-8s %-8s\n' NAME IP CPUS RAM_MB DISK_GB SSH_PORT
            awk -F: '{printf "%-15s %-18s %-6s %-8s %-8s %-8s\n",$1,$2,$3,$4,$5,$6}' "${NODES_DB}"
        fi
        ;;

    destroy)
        NODE_NAME="${1:?Usage: destroy <name>}"
        NODE_DIR="${NODES_DIR}/${NODE_NAME}"
        PID_FILE="${NODE_DIR}/${NODE_NAME}.pid"
        if [ -f "${PID_FILE}" ]; then
            PID="$(cat "${PID_FILE}")"
            kill "${PID}" 2>/dev/null && log "Node '${NODE_NAME}' stopped (PID ${PID})" || true
            rm -f "${PID_FILE}"
        fi
        sed -i "/^${NODE_NAME}:/d" "${NODES_DB}" 2>/dev/null || true
        rm -rf "${NODE_DIR}"
        log "Node '${NODE_NAME}' destroyed."
        ;;

    *)
        printf 'Usage: %s create|list|destroy\n' "$0" >&2
        exit 1
        ;;
esac
