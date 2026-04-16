#!/usr/bin/env sh
# layer3-vps/expose/api-endpoint.sh
# Ensures the REST API server is running and accessible.
# Idempotent.
set -eu

log() { printf '[expose:api] %s\n' "$*"; }

API_PORT=8080
API_PID_FILE="/vps/run/api.pid"
API_SCRIPT="/vps/apps/api/server.py"
API_LOG="/vps/logs/api.log"

mkdir -p /vps/run /vps/logs

# ── Check if already running ──────────────────────────────────────────────────
if [ -f "${API_PID_FILE}" ] && kill -0 "$(cat "${API_PID_FILE}")" 2>/dev/null; then
    log "API server already running on :${API_PORT} (PID $(cat "${API_PID_FILE}"))"
    exit 0
fi

# ── Start API server ──────────────────────────────────────────────────────────
if [ -f "${API_SCRIPT}" ]; then
    log "Starting API server on :${API_PORT} …"
    nohup python3 "${API_SCRIPT}" > "${API_LOG}" 2>&1 &
    echo $! > "${API_PID_FILE}"
    log "API server PID: $(cat "${API_PID_FILE}")"
else
    log "API script not found at ${API_SCRIPT} — run vserver/apps.sh first"
    exit 1
fi

# ── Firewall: allow API port ──────────────────────────────────────────────────
iptables -C INPUT -p tcp --dport "${API_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "${API_PORT}" -j ACCEPT 2>/dev/null || true

log "API endpoint exposed on :${API_PORT}"
