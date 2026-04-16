#!/usr/bin/env bash
# spark-resume.sh - Start Spark vLLM via docker compose and switch LiteLLM to agent-mode

set -euo pipefail

SCRIPT_LABEL="spark-resume"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

require_command curl
require_command ssh
require_command python3

ensure_runtime_dirs
ensure_litellm_installed

RESUME_LOCKFILE="${SPARK_AGENTS_HOME}/spark-resume.pid"
if [ -f "${RESUME_LOCKFILE}" ] && kill -0 "$(cat "${RESUME_LOCKFILE}" 2>/dev/null)" 2>/dev/null; then
    err "Another spark-resume is already running (PID $(cat "${RESUME_LOCKFILE}")). Refusing to re-enter; this prevents SIGKILLing an in-flight model load."
    exit 1
fi
echo "$$" > "${RESUME_LOCKFILE}"
trap 'rm -f "${RESUME_LOCKFILE}"' EXIT

log "Starting Spark vLLM via docker compose..."
ssh "${SPARK_USER}@${SPARK_HOST}" "cd ${SPARK_COMPOSE_DIR} && sudo docker compose up -d"

log "Waiting for Spark SuperGemma vLLM..."
wait_for_models_endpoint "${SPARK_SUPERGEMMA_V1_URL}" "Spark SuperGemma vLLM" 300
healthcheck_chat_completion "${SPARK_SUPERGEMMA_V1_URL}" "${SUPERGEMMA_MODEL_ID}" "Spark SuperGemma vLLM"

log "Switching LiteLLM to agent-mode..."
restart_litellm "agent-mode"

echo ""
log "Spark-local serving is back."
log "  LiteLLM mode: agent-mode"
log "  general -> ${SUPERGEMMA_MODEL_ID}"

if ! pgrep -f "hermes" > /dev/null 2>&1; then
    warn "Hermes is not running. mba-deploy.sh starts it the first time."
fi

if ! pgrep -f "openclaw" > /dev/null 2>&1; then
    warn "OpenClaw is not running. mba-deploy.sh starts it the first time."
fi
