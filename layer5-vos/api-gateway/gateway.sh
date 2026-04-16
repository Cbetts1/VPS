#!/usr/bin/env sh
# layer5-vos/api-gateway/gateway.sh
# vOS API Gateway — Python-based HTTP reverse proxy / router.
# Routes:
#   GET  /vos/status       → vOS status JSON
#   GET  /vos/services     → list of services
#   POST /vos/pkg/install  → install a package
#   POST /vos/node/spawn   → spawn a new vCloud node
#   GET  /vos/net          → list virtual networks
# Usage: sh gateway.sh start|stop|status
# Idempotent.
set -eu

GATEWAY_PORT=9000
GATEWAY_PID="/vos/var/run/gateway.pid"
GATEWAY_LOG="/vos/var/log/gateway.log"
GATEWAY_SCRIPT="/vos/srv/api/gateway.py"

log() { printf '[vos:gateway] %s\n' "$*"; }
mkdir -p /vos/var/run /vos/var/log /vos/srv/api

CMD="${1:-start}"

# ── Write Python gateway script (idempotent) ──────────────────────────────────
if [ ! -f "${GATEWAY_SCRIPT}" ]; then
    cat > "${GATEWAY_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
"""vOS API Gateway — lightweight HTTP router."""
import json
import os
import platform
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("GATEWAY_PORT", "9000"))
VOS_ROOT = os.environ.get("VOS_ROOT", "/vos")

def run(cmd):
    """Run shell command and return (stdout, returncode)."""
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return r.stdout.strip(), r.returncode

def vos_status():
    uptime = "unknown"
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
            uptime = f"{int(secs//3600)}h {int((secs%3600)//60)}m"
    except Exception:
        pass
    version = "unknown"
    try:
        with open(f"{VOS_ROOT}/etc/vos-version") as f:
            version = f.read().strip()
    except Exception:
        pass
    return {
        "vos": "running",
        "version": version,
        "hostname": platform.node(),
        "arch": platform.machine(),
        "uptime": uptime,
        "timestamp": int(time.time()),
    }

class GatewayHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/vos/status"):
            self.send_json(200, vos_status())
        elif path == "/vos/services":
            out, _ = run(f"sh /mnt/host-scripts/layer5-vos/service-manager/services.sh list 2>&1")
            self.send_json(200, {"services": out.splitlines()})
        elif path == "/vos/net":
            out, _ = run(f"sh /mnt/host-scripts/layer5-vos/networking/vnet.sh list 2>&1")
            self.send_json(200, {"networks": out.splitlines()})
        elif path == "/vos/nodes":
            out, _ = run(f"sh /mnt/host-scripts/layer4-vcloud/virtual-nodes.sh list 2>&1")
            self.send_json(200, {"nodes": out.splitlines()})
        else:
            self.send_json(404, {"error": "not found", "path": path})

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else "{}"
        try:
            data = json.loads(body) if body else {}
        except Exception:
            data = {}

        if path == "/vos/pkg/install":
            pkg = data.get("package", "")
            if not pkg:
                self.send_json(400, {"error": "missing 'package' field"})
                return
            out, rc = run(f"sh /mnt/host-scripts/layer5-vos/package-manager/vpkg.sh install {pkg} 2>&1")
            self.send_json(200 if rc == 0 else 500, {"output": out, "rc": rc})

        elif path == "/vos/node/spawn":
            name = data.get("name", f"node-{int(time.time())}")
            cpus = data.get("cpus", 1)
            ram  = data.get("ram_mb", 256)
            disk = data.get("disk_gb", 4)
            out, rc = run(
                f"sh /mnt/host-scripts/layer4-vcloud/virtual-nodes.sh "
                f"create {name} {cpus} {ram} {disk} 2>&1"
            )
            self.send_json(200 if rc == 0 else 500, {"output": out, "rc": rc, "name": name})

        elif path == "/vos/vps/spawn":
            name = data.get("name", f"vps-{int(time.time())}")
            out, rc = run(
                f"sh /mnt/host-scripts/layer4-vcloud/spawn-vps.sh "
                f"{name} {data.get('cpus',2)} {data.get('ram_mb',1024)} {data.get('disk_gb',8)} 2>&1"
            )
            self.send_json(200 if rc == 0 else 500, {"output": out, "rc": rc, "name": name})

        else:
            self.send_json(404, {"error": "not found", "path": path})

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), GatewayHandler)
    print(f"vOS API Gateway listening on :{PORT}", flush=True)
    server.serve_forever()
PYEOF
    chmod +x "${GATEWAY_SCRIPT}"
    log "Gateway script written: ${GATEWAY_SCRIPT}"
fi

case "${CMD}" in
    start)
        if [ -f "${GATEWAY_PID}" ] && kill -0 "$(cat "${GATEWAY_PID}")" 2>/dev/null; then
            log "Gateway already running (PID $(cat "${GATEWAY_PID}"))"
            exit 0
        fi
        log "Starting API Gateway on :${GATEWAY_PORT} …"
        GATEWAY_PORT="${GATEWAY_PORT}" VOS_ROOT="/vos" \
            nohup python3 "${GATEWAY_SCRIPT}" > "${GATEWAY_LOG}" 2>&1 &
        echo $! > "${GATEWAY_PID}"
        log "Gateway PID: $(cat "${GATEWAY_PID}")"
        ;;
    stop)
        if [ -f "${GATEWAY_PID}" ]; then
            PID="$(cat "${GATEWAY_PID}")"
            kill "${PID}" 2>/dev/null && log "Gateway stopped (PID ${PID})" || log "Not running"
            rm -f "${GATEWAY_PID}"
        fi
        ;;
    status)
        if [ -f "${GATEWAY_PID}" ] && kill -0 "$(cat "${GATEWAY_PID}")" 2>/dev/null; then
            log "RUNNING on :${GATEWAY_PORT} (PID $(cat "${GATEWAY_PID}"))"
        else
            log "STOPPED"
        fi
        ;;
    *)
        printf 'Usage: %s start|stop|status\n' "$0" >&2; exit 1
        ;;
esac
