#!/usr/bin/env sh
# layer5-vos/package-manager/vpkg.sh
# vOS native package manager.
# Packages are tarballs in /vos/var/lib/pkg/cache/.
# Usage: vpkg install|remove|list|search|update [pkg]
# Idempotent.
set -eu

VOS_ROOT="/vos"
PKG_DB="${VOS_ROOT}/var/lib/pkg/installed.db"
PKG_CACHE="${VOS_ROOT}/var/lib/pkg/cache"
PKG_REPO="${VPKG_REPO:-https://dl-cdn.alpinelinux.org/alpine/v3.19/main/$(uname -m)}"

log() { printf '[vpkg] %s\n' "$*"; }
mkdir -p "${PKG_CACHE}" "$(dirname "${PKG_DB}")"
touch "${PKG_DB}"

CMD="${1:-list}"
shift || true

case "${CMD}" in
    install)
        PKG="${1:?Usage: vpkg install <package>}"
        if grep -q "^${PKG}$" "${PKG_DB}" 2>/dev/null; then
            log "Already installed: ${PKG}"
            exit 0
        fi
        # Delegate to system apk if available
        if command -v apk >/dev/null 2>&1; then
            log "Installing via apk: ${PKG}"
            apk add --no-cache "${PKG}"
            echo "${PKG}" >> "${PKG_DB}"
            log "Installed: ${PKG}"
        else
            log "ERROR: apk not available. Cannot install '${PKG}'."
            exit 1
        fi
        ;;

    remove)
        PKG="${1:?Usage: vpkg remove <package>}"
        if command -v apk >/dev/null 2>&1; then
            apk del "${PKG}" 2>/dev/null || true
        fi
        sed -i "/^${PKG}$/d" "${PKG_DB}" 2>/dev/null || true
        log "Removed: ${PKG}"
        ;;

    update)
        log "Updating package index …"
        command -v apk >/dev/null 2>&1 && apk update -q || log "WARNING: apk not available"
        ;;

    search)
        QUERY="${1:-}"
        command -v apk >/dev/null 2>&1 && apk search "${QUERY}" || log "apk not available"
        ;;

    list)
        log "=== Installed vOS packages ==="
        if [ -s "${PKG_DB}" ]; then
            cat "${PKG_DB}"
        else
            log "(none)"
        fi
        ;;

    help|*)
        printf 'vpkg — vOS package manager\n'
        printf 'Usage: vpkg install|remove|update|search|list [pkg]\n'
        ;;
esac
