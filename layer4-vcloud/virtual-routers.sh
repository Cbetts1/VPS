#!/usr/bin/env sh
# layer4-vcloud/virtual-routers.sh
# Creates and manages virtual routers using WireGuard or iptables/bridge.
# Each router is a namespace + routing table entry.
# Usage: sh virtual-routers.sh create <name> <upstream_if>
#        sh virtual-routers.sh list
#        sh virtual-routers.sh destroy <name>
# Idempotent.
set -eu

ROUTERS_DB="/vps/vcloud/routers.db"
log() { printf '[vcloud:routers] %s\n' "$*"; }
mkdir -p /vps/vcloud
touch "${ROUTERS_DB}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    create)
        ROUTER_NAME="${1:?Usage: create <name> <upstream_if>}"
        UPSTREAM_IF="${2:-eth0}"

        if grep -q "^${ROUTER_NAME}:" "${ROUTERS_DB}" 2>/dev/null; then
            log "Router '${ROUTER_NAME}' already exists."
            exit 0
        fi

        # Create network namespace
        ip netns add "${ROUTER_NAME}" 2>/dev/null || log "Namespace '${ROUTER_NAME}' may already exist"

        # Create veth pair: vr-<name>-h ↔ vr-<name>-ns
        HOST_VETH="vr-$(echo "${ROUTER_NAME}" | cut -c1-8)-h"
        NS_VETH="vr-$(echo "${ROUTER_NAME}" | cut -c1-8)-n"

        if ! ip link show "${HOST_VETH}" >/dev/null 2>&1; then
            ip link add "${HOST_VETH}" type veth peer name "${NS_VETH}" 2>/dev/null || true
        fi

        # Move NS end into namespace
        ip link set "${NS_VETH}" netns "${ROUTER_NAME}" 2>/dev/null || true

        # Assign IPs — pick from 172.16.x.0/30 range
        LAST_ROUTER="$(wc -l < "${ROUTERS_DB}")"
        HOST_IP="172.16.$((LAST_ROUTER + 1)).1"
        NS_IP="172.16.$((LAST_ROUTER + 1)).2"

        ip addr add "${HOST_IP}/30" dev "${HOST_VETH}" 2>/dev/null || true
        ip link set "${HOST_VETH}" up 2>/dev/null || true
        ip netns exec "${ROUTER_NAME}" ip addr add "${NS_IP}/30" dev "${NS_VETH}" 2>/dev/null || true
        ip netns exec "${ROUTER_NAME}" ip link set "${NS_VETH}" up 2>/dev/null || true
        ip netns exec "${ROUTER_NAME}" ip link set lo up 2>/dev/null || true

        # Default route in namespace
        ip netns exec "${ROUTER_NAME}" ip route add default via "${HOST_IP}" 2>/dev/null || true

        # NAT from namespace
        iptables -t nat -A POSTROUTING -s "${NS_IP}/30" -o "${UPSTREAM_IF}" -j MASQUERADE 2>/dev/null || true

        printf '%s:%s:%s:%s\n' "${ROUTER_NAME}" "${HOST_IP}" "${NS_IP}" "${UPSTREAM_IF}" >> "${ROUTERS_DB}"
        log "Router '${ROUTER_NAME}' created: host=${HOST_IP} ns=${NS_IP}"
        ;;

    list)
        if [ ! -s "${ROUTERS_DB}" ]; then
            log "No virtual routers."
        else
            printf '%-15s %-15s %-15s %-10s\n' NAME HOST_IP NS_IP UPSTREAM
            awk -F: '{printf "%-15s %-15s %-15s %-10s\n",$1,$2,$3,$4}' "${ROUTERS_DB}"
        fi
        ;;

    destroy)
        ROUTER_NAME="${1:?Usage: destroy <name>}"
        ip netns del "${ROUTER_NAME}" 2>/dev/null || true
        HOST_VETH="vr-$(echo "${ROUTER_NAME}" | cut -c1-8)-h"
        ip link del "${HOST_VETH}" 2>/dev/null || true
        sed -i "/^${ROUTER_NAME}:/d" "${ROUTERS_DB}" 2>/dev/null || true
        log "Router '${ROUTER_NAME}' destroyed."
        ;;

    *)
        printf 'Usage: %s create|list|destroy\n' "$0" >&2; exit 1
        ;;
esac
