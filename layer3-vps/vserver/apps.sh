#!/usr/bin/env sh
# layer3-vps/vserver/apps.sh
# Deploys core VPS applications:
#   - A minimal REST API server (Python/http.server)
#   - Web console static files
# Idempotent.
set -eu

log() { printf '[vserver:apps] %s\n' "$*"; }

APPS_DIR="/vps/apps"
API_DIR="${APPS_DIR}/api"
CONSOLE_DIR="${APPS_DIR}/webconsole"
API_PORT=8080

mkdir -p "${API_DIR}" "${CONSOLE_DIR}"

# ── Minimal Python REST API ───────────────────────────────────────────────────
API_SCRIPT="${API_DIR}/server.py"
if [ ! -f "${API_SCRIPT}" ]; then
    cat > "${API_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
"""vOS REST API server — minimal, self-contained."""
import json
import os
import platform
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("API_PORT", "8080"))

def get_status():
    uptime = ""
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
            uptime = f"{int(secs // 3600)}h {int((secs % 3600) // 60)}m"
    except Exception:
        uptime = "unknown"
    return {
        "vos": "running",
        "hostname": platform.node(),
        "arch": platform.machine(),
        "uptime": uptime,
        "timestamp": int(time.time()),
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # suppress default access log
        pass

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "/api/status":
            self.send_json(200, get_status())
        elif self.path == "/api/version":
            version = "unknown"
            try:
                with open("/etc/vm2-version") as f:
                    version = f.read().strip()
            except Exception:
                pass
            self.send_json(200, {"vm2_version": version})
        else:
            self.send_json(404, {"error": "not found"})

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"vOS API listening on :{PORT}")
    server.serve_forever()
PYEOF
    chmod +x "${API_SCRIPT}"
    log "REST API script created: ${API_SCRIPT}"
fi

# ── Web console index.html ────────────────────────────────────────────────────
INDEX_HTML="${CONSOLE_DIR}/index.html"
if [ ! -f "${INDEX_HTML}" ]; then
    cat > "${INDEX_HTML}" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>vOS Web Console</title>
  <style>
    body { font-family: monospace; background:#111; color:#0f0; margin:2em; }
    h1   { color:#0af; }
    pre  { background:#000; padding:1em; border:1px solid #0f0; }
    button { background:#0af; color:#000; border:none; padding:.5em 1em; cursor:pointer; }
  </style>
</head>
<body>
  <h1>vOS Web Console</h1>
  <pre id="status">Loading status…</pre>
  <button onclick="refresh()">Refresh</button>
  <script>
    async function refresh() {
      try {
        const r = await fetch('/api/status');
        const d = await r.json();
        document.getElementById('status').textContent = JSON.stringify(d, null, 2);
      } catch(e) {
        document.getElementById('status').textContent = 'Error: ' + e;
      }
    }
    refresh();
    setInterval(refresh, 10000);
  </script>
</body>
</html>
HTML
    log "Web console HTML created: ${INDEX_HTML}"
fi

# ── Start API server (if not running) ────────────────────────────────────────
API_PID_FILE="/vps/run/api.pid"
if [ -f "${API_PID_FILE}" ] && kill -0 "$(cat "${API_PID_FILE}")" 2>/dev/null; then
    log "API server already running (PID $(cat "${API_PID_FILE}"))"
else
    log "Starting API server on :${API_PORT} …"
    nohup python3 "${API_SCRIPT}" > /vps/logs/api.log 2>&1 &
    echo $! > "${API_PID_FILE}"
    log "API server PID: $(cat "${API_PID_FILE}")"
fi

log "vServer apps deployed."
