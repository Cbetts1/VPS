#!/usr/bin/env sh
# layer1-vm1/self-update.sh
# Pulls latest scripts from the repo and re-executes the requested target.
# Usage: sh self-update.sh [--target <script>]
# Idempotent — subsequent calls get the same result if repo is unchanged.
set -eu

REPO_URL="${REPO_URL:-https://github.com/Cbetts1/VPS.git}"
REPO_DIR="/opt/vps-chain"
TARGET="${1:-}"

log() { printf '[self-update] %s\n' "$*"; }

# ── Clone or pull ──────────────────────────────────────────────────────────────
if [ -d "${REPO_DIR}/.git" ]; then
    log "Pulling latest changes …"
    git -C "${REPO_DIR}" fetch --quiet origin
    git -C "${REPO_DIR}" reset --quiet --hard origin/main
else
    log "Cloning repository …"
    git clone --quiet --depth 1 "${REPO_URL}" "${REPO_DIR}"
fi

log "Repository at ${REPO_DIR} is up to date."

# ── Make all scripts executable ────────────────────────────────────────────────
find "${REPO_DIR}" -name '*.sh' -exec chmod +x {} \;

# ── Re-execute target if provided ─────────────────────────────────────────────
if [ -n "${TARGET}" ] && [ -f "${REPO_DIR}/${TARGET}" ]; then
    log "Re-executing: ${TARGET}"
    exec sh "${REPO_DIR}/${TARGET}"
fi
