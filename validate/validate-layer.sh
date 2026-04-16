#!/usr/bin/env sh
# validate/validate-layer.sh
# Validates a single named layer.
# Usage: sh validate-layer.sh <layer>
# Layers: phone, vm1, vm2, vps, vcloud, vos
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAYER="${1:?Usage: validate-layer.sh <phone|vm1|vm2|vps|vcloud|vos>}"

log()  { printf '[validate:%s] %s\n' "${LAYER}" "$*"; }
pass() { printf '[validate:%s] ✔ %s\n' "${LAYER}" "$*"; }
fail() { printf '[validate:%s] ✘ %s\n' "${LAYER}" "$*" >&2; }

ERRORS=0

check_script() {
    script="$1"
    if [ -f "${REPO_ROOT}/${script}" ]; then
        if sh -n "${REPO_ROOT}/${script}" 2>/dev/null; then
            pass "${script} — syntax OK"
        else
            fail "${script} — syntax ERROR"
            ERRORS=$(( ERRORS + 1 ))
        fi
    else
        fail "${script} — file NOT FOUND"
        ERRORS=$(( ERRORS + 1 ))
    fi
}

case "${LAYER}" in
    phone)
        check_script "layer0-phone/detect-host.sh"
        check_script "layer0-phone/build-vm1.sh"
        ;;
    vm1)
        check_script "layer1-vm1/spec-evaluator.sh"
        check_script "layer1-vm1/self-update.sh"
        check_script "layer1-vm1/vm-builder.sh"
        check_script "layer1-vm1/build-vm2.sh"
        # Check cloud-init files
        [ -f "${REPO_ROOT}/layer1-vm1/cloud-init/user-data" ] && pass "cloud-init/user-data present" || { fail "cloud-init/user-data missing"; ERRORS=$(( ERRORS + 1 )); }
        [ -f "${REPO_ROOT}/layer1-vm1/cloud-init/meta-data" ] && pass "cloud-init/meta-data present" || { fail "cloud-init/meta-data missing"; ERRORS=$(( ERRORS + 1 )); }
        ;;
    vm2)
        check_script "layer2-vm2/validate-env.sh"
        check_script "layer2-vm2/version-counter.sh"
        check_script "layer2-vm2/doubling-spec.sh"
        check_script "layer2-vm2/rebuild-self.sh"
        check_script "layer2-vm2/build-vps.sh"
        ;;
    vps)
        check_script "layer3-vps/vhost/setup-filesystem.sh"
        check_script "layer3-vps/vhost/boot-scripts/boot.sh"
        check_script "layer3-vps/vcpu/instruction-engine.sh"
        check_script "layer3-vps/vos-kernel/services.sh"
        check_script "layer3-vps/vos-kernel/package-manager.sh"
        check_script "layer3-vps/vserver/apps.sh"
        check_script "layer3-vps/vcloud-layer/networking.sh"
        check_script "layer3-vps/expose/ssh-setup.sh"
        check_script "layer3-vps/expose/api-endpoint.sh"
        check_script "layer3-vps/expose/web-console.sh"
        ;;
    vcloud)
        check_script "layer4-vcloud/virtual-nodes.sh"
        check_script "layer4-vcloud/virtual-routers.sh"
        check_script "layer4-vcloud/virtual-storage.sh"
        check_script "layer4-vcloud/virtual-compute.sh"
        check_script "layer4-vcloud/spawn-vps.sh"
        ;;
    vos)
        check_script "layer5-vos/kernel/layout.sh"
        check_script "layer5-vos/service-manager/services.sh"
        check_script "layer5-vos/filesystem/vfs.sh"
        check_script "layer5-vos/networking/vnet.sh"
        check_script "layer5-vos/package-manager/vpkg.sh"
        check_script "layer5-vos/boot/sequence.sh"
        check_script "layer5-vos/api-gateway/gateway.sh"
        ;;
    *)
        log "Unknown layer '${LAYER}'. Valid: phone vm1 vm2 vps vcloud vos"
        exit 1
        ;;
esac

if [ "${ERRORS}" -eq 0 ]; then
    log "All checks PASSED (${LAYER})"
    exit 0
else
    log "FAILED — ${ERRORS} issue(s) in layer '${LAYER}'"
    exit 1
fi
