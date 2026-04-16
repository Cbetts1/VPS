#!/usr/bin/env sh
# layer5-vos/service-manager/services.sh
# vOS service manager: start/stop/status/list vOS services.
# Services are defined as simple shell scripts in /vos/etc/services.d/
# Usage: sh services.sh start|stop|restart|status|list [service_name]
# Idempotent.
set -eu

VOS_ROOT="/vos"
SERVICES_DIR="${VOS_ROOT}/etc/services.d"
PIDS_DIR="${VOS_ROOT}/var/run"
LOG_DIR="${VOS_ROOT}/var/log"

log() { printf '[vos:svcmgr] %s\n' "$*"; }
mkdir -p "${SERVICES_DIR}" "${PIDS_DIR}" "${LOG_DIR}"

CMD="${1:-list}"
SVC="${2:-}"

# ── Helper functions ──────────────────────────────────────────────────────────
svc_start() {
    name="$1"
    script="${SERVICES_DIR}/${name}.sh"
    pidfile="${PIDS_DIR}/${name}.pid"
    logfile="${LOG_DIR}/${name}.log"

    if [ ! -f "${script}" ]; then
        log "Service '${name}' not found at ${script}"
        return 1
    fi
    if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
        log "Service '${name}' already running (PID $(cat "${pidfile}"))"
        return 0
    fi
    log "Starting ${name} …"
    nohup sh "${script}" >> "${logfile}" 2>&1 &
    echo $! > "${pidfile}"
    log "${name} started (PID $(cat "${pidfile}"))"
}

svc_stop() {
    name="$1"
    pidfile="${PIDS_DIR}/${name}.pid"
    if [ -f "${pidfile}" ]; then
        PID="$(cat "${pidfile}")"
        kill "${PID}" 2>/dev/null && log "${name} stopped (PID ${PID})" || log "${name} not running"
        rm -f "${pidfile}"
    else
        log "Service '${name}' is not running."
    fi
}

svc_status() {
    name="$1"
    pidfile="${PIDS_DIR}/${name}.pid"
    if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
        log "${name}: RUNNING (PID $(cat "${pidfile}"))"
    else
        log "${name}: STOPPED"
    fi
}

case "${CMD}" in
    start)
        if [ -n "${SVC}" ]; then
            svc_start "${SVC}"
        else
            # Start all
            for s in "${SERVICES_DIR}"/*.sh; do
                [ -f "${s}" ] && svc_start "$(basename "${s}" .sh)" || true
            done
        fi
        ;;
    stop)
        if [ -n "${SVC}" ]; then
            svc_stop "${SVC}"
        else
            for s in "${SERVICES_DIR}"/*.sh; do
                [ -f "${s}" ] && svc_stop "$(basename "${s}" .sh)" || true
            done
        fi
        ;;
    restart)
        svc_stop "${SVC:-}"
        svc_start "${SVC:-}"
        ;;
    status)
        if [ -n "${SVC}" ]; then
            svc_status "${SVC}"
        else
            for s in "${SERVICES_DIR}"/*.sh; do
                [ -f "${s}" ] && svc_status "$(basename "${s}" .sh)" || true
            done
        fi
        ;;
    list)
        log "=== Registered vOS Services ==="
        for s in "${SERVICES_DIR}"/*.sh; do
            [ -f "${s}" ] && printf '  %s\n' "$(basename "${s}" .sh)" || true
        done
        ;;
    *)
        printf 'Usage: %s start|stop|restart|status|list [service]\n' "$0" >&2
        exit 1
        ;;
esac
