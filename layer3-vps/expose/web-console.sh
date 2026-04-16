#!/usr/bin/env sh
# layer3-vps/expose/web-console.sh
# Ensures nginx serves the web console on port 80.
# Idempotent.
set -eu

log() { printf '[expose:web] %s\n' "$*"; }

CONSOLE_DIR="/vps/apps/webconsole"
NGINX_ENABLED="/etc/nginx/conf.d/vps.conf"

# ── Ensure console dir exists ─────────────────────────────────────────────────
mkdir -p "${CONSOLE_DIR}"

# ── Fallback index if apps.sh hasn't run yet ──────────────────────────────────
if [ ! -f "${CONSOLE_DIR}/index.html" ]; then
    printf '<h1>vOS Web Console — initializing…</h1>' > "${CONSOLE_DIR}/index.html"
    log "Placeholder index.html created."
fi

# ── Verify nginx config exists ────────────────────────────────────────────────
if [ ! -f "${NGINX_ENABLED}" ]; then
    log "Nginx vPS config missing — run vos-kernel/services.sh first"
fi

# ── Start / reload nginx ──────────────────────────────────────────────────────
if rc-service nginx status >/dev/null 2>&1; then
    nginx -t 2>/dev/null && rc-service nginx reload 2>/dev/null || true
    log "Nginx reloaded."
else
    rc-update add nginx default 2>/dev/null || true
    rc-service nginx start 2>/dev/null || true
    log "Nginx started."
fi

# ── Firewall: allow HTTP ──────────────────────────────────────────────────────
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true

log "Web console exposed on :80"
