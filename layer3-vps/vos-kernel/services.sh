#!/usr/bin/env sh
# layer3-vps/vos-kernel/services.sh
# Starts and configures core vOS services on the VPS.
# Services: sshd, nginx (web/api proxy), cron, syslog.
# Idempotent — uses rc-service/rc-update (Alpine OpenRC).
set -eu

log() { printf '[vos:services] %s\n' "$*"; }

# Helper: enable + start a service if available
enable_service() {
    svc="$1"
    if rc-service "${svc}" status >/dev/null 2>&1 || command -v "${svc}" >/dev/null 2>&1; then
        rc-update add "${svc}" default 2>/dev/null || true
        rc-service "${svc}" start 2>/dev/null || rc-service "${svc}" restart 2>/dev/null || true
        log "Service enabled: ${svc}"
    else
        log "Service not found, skipping: ${svc}"
    fi
}

# ── Core services ─────────────────────────────────────────────────────────────
enable_service sshd
enable_service crond
enable_service syslog

# ── Nginx config for API proxy ────────────────────────────────────────────────
NGINX_CONF="/etc/nginx/conf.d/vps.conf"
mkdir -p /etc/nginx/conf.d

if [ ! -f "${NGINX_CONF}" ]; then
    cat > "${NGINX_CONF}" <<'EOF'
# vOS nginx vPS frontend
server {
    listen 80 default_server;
    server_name _;

    location / {
        root /vps/apps/webconsole;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
    log "Nginx vPS config written."
fi

enable_service nginx

log "vOS services configured."
