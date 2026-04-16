#!/usr/bin/env sh
# layer2-vm2/version-counter.sh
# Reads, increments, and writes /etc/vm2-version.
# Usage:
#   sh version-counter.sh get      → prints current version (default 0)
#   sh version-counter.sh bump     → increments and writes new version, prints it
#   sh version-counter.sh reset    → resets to 0
# Idempotent for 'get' and 'reset'.
set -eu

VERSION_FILE="${VERSION_FILE:-/etc/vm2-version}"
COMMAND="${1:-get}"

log() { printf '[version-counter] %s\n' "$*" >&2; }

read_version() {
    if [ -f "${VERSION_FILE}" ]; then
        cat "${VERSION_FILE}"
    else
        echo "0"
    fi
}

case "${COMMAND}" in
    get)
        read_version
        ;;
    bump)
        CURRENT="$(read_version)"
        NEXT=$(( CURRENT + 1 ))
        printf '%s\n' "${NEXT}" > "${VERSION_FILE}"
        log "Version bumped: ${CURRENT} → ${NEXT}"
        echo "${NEXT}"
        ;;
    reset)
        printf '0\n' > "${VERSION_FILE}"
        log "Version reset to 0"
        echo "0"
        ;;
    *)
        printf 'Usage: %s [get|bump|reset]\n' "$0" >&2
        exit 1
        ;;
esac
