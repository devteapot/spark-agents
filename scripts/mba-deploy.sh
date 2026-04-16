#!/usr/bin/env bash
# mba-deploy.sh - Deploy the always-on MBA side of the stack
#
# Run this on the MBA from inside the repo checkout. It will:
#   1. Stage Hermes, OpenClaw, and LiteLLM configs into ~/.spark-agents
#   2. Copy the live agent configs into ~/.hermes and ~/.openclaw
#   3. Ensure LiteLLM is installed and restart it in the active mode
#   4. Restart Hermes and OpenClaw once so they pick up the new router-backed configs
#   5. Install the operational scripts into ~/bin
#
# Usage:
#   cd spark-agents
#   ./scripts/mba-deploy.sh

set -euo pipefail

SCRIPT_LABEL="deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

HERMES_REPO_CONFIG="${PROJECT_DIR}/hermes/cli-config.yaml"
OPENCLAW_REPO_CONFIG="${PROJECT_DIR}/openclaw/config.json"
LITELLM_AGENT_REPO_CONFIG="${PROJECT_DIR}/litellm/agent-mode.yaml"
LITELLM_OFFLOAD_REPO_CONFIG="${PROJECT_DIR}/litellm/offload-mode.yaml"

RUNTIME_HERMES_DIR="${SPARK_AGENTS_HOME}/hermes"
RUNTIME_OPENCLAW_DIR="${SPARK_AGENTS_HOME}/openclaw"

DEFAULT_MODE="offload-mode"

ensure_npm_global_bin_on_path() {
    local prefix=""

    if ! command -v npm > /dev/null 2>&1; then
        return 0
    fi

    prefix="$(npm config get prefix 2>/dev/null || true)"
    if [ -n "${prefix}" ] && [ -d "${prefix}/bin" ]; then
        PATH="${prefix}/bin:${PATH}"
        export PATH
    fi
}

stop_process_if_running() {
    local name="$1"
    local stop_cmd="$2"

    if ! pgrep -f "${name}" > /dev/null 2>&1; then
        log "${name} was not running."
        return 0
    fi

    log "Stopping ${name}..."
    eval "${stop_cmd}" || true
    sleep 1

    if pgrep -f "${name}" > /dev/null 2>&1; then
        pkill -TERM -f "${name}" 2>/dev/null || true
        sleep 1
    fi

    if pgrep -f "${name}" > /dev/null 2>&1; then
        pkill -9 -f "${name}" 2>/dev/null || true
    fi
}

start_process_if_needed() {
    local name="$1"
    local start_cmd="$2"
    local log_file="$3"

    if pgrep -f "${name}" > /dev/null 2>&1; then
        warn "${name} is already running."
        return 0
    fi

    log "Starting ${name}..."
    nohup sh -c "${start_cmd}" > "${log_file}" 2>&1 &
    sleep 2

    if pgrep -f "${name}" > /dev/null 2>&1; then
        log "${name} started. Log: ${log_file}"
    else
        err "${name} failed to start. Check ${log_file}"
        return 1
    fi
}

hermes_gateway_configured() {
    python3 - "${HOME}/.hermes/cli-config.yaml" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except Exception:
    raise SystemExit(1)

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

data = yaml.safe_load(path.read_text()) or {}
gateway = data.get("gateway")
if isinstance(gateway, dict) and gateway:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

render_openclaw_runtime_config() {
    python3 - "${RUNTIME_OPENCLAW_DIR}/config.json" "${HOME}/.openclaw/openclaw.json" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

data = json.loads(src.read_text())
data.pop("_comment", None)

gateway = data.setdefault("gateway", {})
gateway.setdefault("mode", "local")
gateway.setdefault("bind", "0.0.0.0")
gateway.setdefault("port", 18789)

control_ui = gateway.setdefault("controlUi", {})
control_ui["allowedOrigins"] = ["*"]

dst.write_text(json.dumps(data, indent=2) + "\n")
PY
}

if [ ! -f "${HERMES_REPO_CONFIG}" ] || [ ! -f "${OPENCLAW_REPO_CONFIG}" ] || [ ! -f "${LITELLM_AGENT_REPO_CONFIG}" ] || [ ! -f "${LITELLM_OFFLOAD_REPO_CONFIG}" ]; then
    err "Repo config files are missing. Run this from inside the spark-agents checkout."
    exit 1
fi

require_command curl
require_command hermes
require_command python3
ensure_npm_global_bin_on_path
ensure_runtime_dirs
ensure_litellm_installed

section "1/7  Staging runtime configs"
mkdir -p "${RUNTIME_HERMES_DIR}" "${RUNTIME_OPENCLAW_DIR}"
cp "${HERMES_REPO_CONFIG}" "${RUNTIME_HERMES_DIR}/cli-config.yaml"
cp "${OPENCLAW_REPO_CONFIG}" "${RUNTIME_OPENCLAW_DIR}/config.json"
cp "${LITELLM_AGENT_REPO_CONFIG}" "${LITELLM_AGENT_CONFIG}"
cp "${LITELLM_OFFLOAD_REPO_CONFIG}" "${LITELLM_OFFLOAD_CONFIG}"

if [ -f "${LITELLM_RUNTIME_DIR}/benchmark-mode.yaml" ]; then
    rm -f "${LITELLM_RUNTIME_DIR}/benchmark-mode.yaml"
fi
if [ -f "${LITELLM_MODE_FILE}" ] && [ "$(cat "${LITELLM_MODE_FILE}")" = "benchmark-mode" ]; then
    printf '%s\n' "offload-mode" > "${LITELLM_MODE_FILE}"
fi
log "Staged repo configs into ${SPARK_AGENTS_HOME}"

section "2/7  Restarting LiteLLM"
CURRENT_MODE="$(current_router_mode)"
if [ "${CURRENT_MODE}" = "unknown" ]; then
    if resolve_openrouter_api_key > /dev/null 2>&1; then
        CURRENT_MODE="${DEFAULT_MODE}"
    else
        CURRENT_MODE="agent-mode"
    fi
fi
restart_litellm "${CURRENT_MODE}"
log "LiteLLM active mode: ${CURRENT_MODE}"

section "3/7  Deploying Hermes config"
mkdir -p "${HOME}/.hermes"
if [ -f "${HOME}/.hermes/config.yaml" ]; then
    cp "${HOME}/.hermes/config.yaml" "${HOME}/.hermes/config.yaml.bak.$(date +%Y%m%d_%H%M%S)"
fi
cp "${RUNTIME_HERMES_DIR}/cli-config.yaml" "${HOME}/.hermes/config.yaml"
rm -f "${HOME}/.hermes/cli-config.yaml"
log "Installed ~/.hermes/config.yaml"

section "4/7  Checking OpenClaw installation"
if command -v openclaw > /dev/null 2>&1; then
    log "OpenClaw already installed ($(openclaw --version 2>/dev/null || echo unknown))"
else
    warn "OpenClaw not found. Attempting install..."
    if command -v npm > /dev/null 2>&1; then
        npm install -g openclaw@latest
        ensure_npm_global_bin_on_path
        if ! command -v openclaw > /dev/null 2>&1; then
            err "OpenClaw was installed with npm but is still not on PATH. npm prefix: $(npm config get prefix 2>/dev/null || echo unknown)"
            exit 1
        fi
        openclaw onboard --install-daemon
    elif command -v brew > /dev/null 2>&1; then
        brew install openclaw
    else
        err "Cannot install OpenClaw automatically. Install it manually and rerun mba-deploy.sh."
        exit 1
    fi
fi

section "5/7  Deploying OpenClaw config"
mkdir -p "${HOME}/.openclaw"
if [ -f "${HOME}/.openclaw/config.json" ]; then
    cp "${HOME}/.openclaw/config.json" "${HOME}/.openclaw/config.json.bak.$(date +%Y%m%d_%H%M%S)"
fi
cp "${RUNTIME_OPENCLAW_DIR}/config.json" "${HOME}/.openclaw/config.json"
render_openclaw_runtime_config
log "Installed ~/.openclaw/config.json and rendered ~/.openclaw/openclaw.json"

section "6/7  Restarting agents on the new router-backed configs"
if hermes_gateway_configured; then
    stop_process_if_running "hermes" "hermes gateway stop 2>/dev/null"
else
    log "Hermes gateway not configured; skipping Hermes background start."
fi
stop_process_if_running "openclaw" "openclaw gateway stop 2>/dev/null"

start_process_if_needed "openclaw" "openclaw gateway run" "/tmp/openclaw.log"

section "7/7  Installing operational scripts"
mkdir -p "${HOME}/bin"
for script in spark-common.sh spark-pause.sh spark-resume.sh spark-status.sh; do
    cp "${PROJECT_DIR}/scripts/${script}" "${HOME}/bin/${script}"
    chmod +x "${HOME}/bin/${script}"
done
log "Installed scripts into ~/bin"

if [[ ":$PATH:" != *":${HOME}/bin:"* ]]; then
    SHELL_RC="${HOME}/.zshrc"
    [ -f "${SHELL_RC}" ] || SHELL_RC="${HOME}/.bashrc"
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "${SHELL_RC}" 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "${SHELL_RC}"
        warn "Added ~/bin to PATH in ${SHELL_RC}. Open a new shell or source it before using spark-*.sh."
    fi
fi

echo ""
section "Deployment Complete"
echo "  LiteLLM endpoint:  ${LITELLM_V1_URL}"
echo "  Router mode:       ${CURRENT_MODE}"
echo "  Hermes config:     ${HOME}/.hermes/cli-config.yaml"
echo "  OpenClaw config:   ${HOME}/.openclaw/config.json"
echo "  OpenClaw gateway:  http://0.0.0.0:18789/"
echo "  LiteLLM configs:   ${LITELLM_RUNTIME_DIR}"
echo ""
echo "  Next steps:"
echo "    1. On Spark: run ./scripts/spark-setup.sh once"
echo "    2. For local serving: spark-resume.sh"
echo "    3. For benchmarking:  spark-pause.sh"
echo "    4. Check health:      spark-status.sh"
