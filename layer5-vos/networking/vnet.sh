#!/usr/bin/env sh
# layer5-vos/networking/vnet.sh
# vOS virtual networking: creates/destroys vnet interfaces (veth pairs + bridge).
# Usage: sh vnet.sh create <net_name> [cidr]
#        sh vnet.sh list
#        sh vnet.sh destroy <net_name>
#        sh vnet.sh connect <net_name> <pid_or_netns>
# Idempotent.
set -eu

VNET_DB="/vos/var/lib/vnet.db"
log() { printf '[vos:vnet] %s\n' "$*"; }
mkdir -p /vos/var/lib
touch "${VNET_DB}"

CMD="${1:-list}"
shift || true

next_cidr() {
    # Assign sequential 10.vos.N.0/24 subnets
    N="$(wc -l < "${VNET_DB}")"
    echo "10.200.$(( N + 1 )).0/24"
}

case "${CMD}" in
    create)
        NET_NAME="${1:?Usage: create <name> [cidr]}"
        CIDR="${2:-$(next_cidr)}"
        GW_IP="$(echo "${CIDR}" | sed 's/\.[0-9]*\/[0-9]*/\.1/')"

        if grep -q "^${NET_NAME}:" "${VNET_DB}" 2>/dev/null; then
            log "vnet '${NET_NAME}' already exists."
            exit 0
        fi

        BR="vbr-${NET_NAME}"
        if ! ip link show "${BR}" >/dev/null 2>&1; then
            ip link add name "${BR}" type bridge 2>/dev/null || true
            ip addr add "${GW_IP}/$(echo "${CIDR}" | cut -d/ -f2)" dev "${BR}" 2>/dev/null || true
            ip link set "${BR}" up 2>/dev/null || true
            log "Bridge ${BR} created: ${CIDR}"
        else
            log "Bridge ${BR} already exists."
        fi

        # NAT masquerade
        iptables -t nat -C POSTROUTING -s "${CIDR}" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "${CIDR}" -j MASQUERADE 2>/dev/null || true

        printf '%s:%s:%s\n' "${NET_NAME}" "${CIDR}" "${BR}" >> "${VNET_DB}"
        log "vnet '${NET_NAME}' ready: ${CIDR} on ${BR}"
        ;;

    list)
        if [ ! -s "${VNET_DB}" ]; then
            log "No virtual networks."
        else
            printf '%-15s %-20s %-12s\n' NAME CIDR BRIDGE
            awk -F: '{printf "%-15s %-20s %-12s\n",$1,$2,$3}' "${VNET_DB}"
        fi
        ;;

    connect)
        NET_NAME="${1:?Usage: connect <net> <netns>}"
        NETNS="${2:?}"
        BR="$(grep "^${NET_NAME}:" "${VNET_DB}" | cut -d: -f3)"
        if [ -z "${BR}" ]; then
            log "vnet '${NET_NAME}' not found."
            exit 1
        fi
        VETH_H="veth-${NET_NAME}-h"
        VETH_N="veth-${NET_NAME}-n"
        ip link add "${VETH_H}" type veth peer name "${VETH_N}" 2>/dev/null || true
        ip link set "${VETH_H}" master "${BR}" 2>/dev/null || true
        ip link set "${VETH_H}" up 2>/dev/null || true
        ip link set "${VETH_N}" netns "${NETNS}" 2>/dev/null || true
        log "Connected netns '${NETNS}' to vnet '${NET_NAME}'."
        ;;

    destroy)
        NET_NAME="${1:?Usage: destroy <name>}"
        BR="$(grep "^${NET_NAME}:" "${VNET_DB}" | cut -d: -f3)"
        if [ -n "${BR}" ]; then
            ip link set "${BR}" down 2>/dev/null || true
            ip link del "${BR}" 2>/dev/null || true
            log "Bridge ${BR} removed."
        fi
        sed -i "/^${NET_NAME}:/d" "${VNET_DB}" 2>/dev/null || true
        log "vnet '${NET_NAME}' destroyed."
        ;;

    *)
        printf 'Usage: %s create|list|connect|destroy\n' "$0" >&2; exit 1
        ;;
esac
