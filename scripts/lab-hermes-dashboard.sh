#!/usr/bin/env bash
# lab-hermes-dashboard.sh — Launch the Hermes dashboard on the MBA for LAN access
#
# Run this on the MBA after lab-resume.sh when you want the Hermes web UI
# reachable from other devices on your local network.
#
# WARNING:
#   Hermes does not put auth in front of this dashboard. It exposes config and
#   API-key management, so only bind it to the LAN if you trust every device
#   and person on that network.
#
# Usage:
#   lab-hermes-dashboard.sh

set -euo pipefail

HOST="${HERMES_DASHBOARD_HOST:-0.0.0.0}"
PORT="${HERMES_DASHBOARD_PORT:-9119}"
LOG_FILE="${TMPDIR:-/tmp}/hermes-dashboard.log"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[hermes-dashboard]${NC} $*"; }
warn() { echo -e "${YELLOW}[hermes-dashboard]${NC} $*"; }
err()  { echo -e "${RED}[hermes-dashboard]${NC} $*" >&2; }

local_hostname() {
    local host
    host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "mba")"
    printf '%s.local' "${host}"
}

local_ipv4() {
    local iface ip
    for iface in en0 en1 bridge0; do
        ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
        if [ -n "${ip}" ]; then
            printf '%s' "${ip}"
            return 0
        fi
    done
    return 1
}

if ! command -v hermes > /dev/null 2>&1; then
    err "Hermes CLI is not installed or not in PATH."
    exit 1
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN > /dev/null 2>&1; then
    warn "Port ${PORT} is already in use."
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN
    exit 1
fi

warn "Binding Hermes to ${HOST}:${PORT}."
warn "This dashboard has no built-in auth; only use it on a trusted LAN."

nohup hermes dashboard --host "${HOST}" --port "${PORT}" --no-open > "${LOG_FILE}" 2>&1 &
PID=$!

sleep 2

if curl -sf "http://localhost:${PORT}/" > /dev/null 2>&1; then
    log "Hermes dashboard started (PID ${PID})."
    echo "  Local: http://localhost:${PORT}/"
    echo "  LAN:   http://$(local_hostname):${PORT}/"
    if IP_ADDR="$(local_ipv4)"; then
        echo "  IP:    http://${IP_ADDR}:${PORT}/"
    fi
    echo "  Log:   ${LOG_FILE}"
else
    err "Hermes dashboard did not start cleanly."
    err "Check ${LOG_FILE} for details."
    exit 1
fi
