#!/usr/bin/env sh
# layer3-vps/vos-kernel/package-manager.sh
# Configures the vOS package manager (wraps Alpine apk).
# Also defines a thin "vpkg" wrapper for use inside vOS.
# Idempotent.
set -eu

log() { printf '[vos:pkgmgr] %s\n' "$*"; }

VPKG_BIN="/usr/local/bin/vpkg"

# ── Ensure apk repos are up to date ──────────────────────────────────────────
if command -v apk >/dev/null 2>&1; then
    log "Updating apk index …"
    apk update -q || log "WARNING: apk update failed (offline?)"
fi

# ── Install vpkg wrapper ──────────────────────────────────────────────────────
if [ ! -f "${VPKG_BIN}" ]; then
    log "Installing vpkg wrapper …"
    cat > "${VPKG_BIN}" <<'VPKG'
#!/usr/bin/env sh
# vpkg — vOS package manager wrapper
# Usage: vpkg install|remove|search|list <package>
set -eu
CMD="${1:-help}"
shift || true

case "${CMD}" in
    install) apk add --no-cache "$@" ;;
    remove)  apk del "$@" ;;
    search)  apk search "$@" ;;
    list)    apk info ;;
    update)  apk update ;;
    upgrade) apk upgrade ;;
    help|*)
        printf 'vpkg — vOS package manager\n'
        printf 'Usage: vpkg install|remove|search|list|update|upgrade [pkg]\n'
        ;;
esac
VPKG
    chmod +x "${VPKG_BIN}"
    log "vpkg installed at ${VPKG_BIN}"
else
    log "vpkg already installed."
fi

log "vOS package manager ready."
