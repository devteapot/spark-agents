#!/usr/bin/env bash
# lab-resume.sh - Start Spark vLLM via docker compose and switch LiteLLM to agent-mode

set -euo pipefail

SCRIPT_LABEL="lab-resume"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lab-common.sh"

require_command curl
require_command ssh
require_command python3

ensure_runtime_dirs
ensure_litellm_installed

RESUME_LOCKFILE="${SPARK_AGENTS_HOME}/lab-resume.pid"
if [ -f "${RESUME_LOCKFILE}" ] && kill -0 "$(cat "${RESUME_LOCKFILE}" 2>/dev/null)" 2>/dev/null; then
    err "Another lab-resume is already running (PID $(cat "${RESUME_LOCKFILE}")). Refusing to re-enter; this prevents SIGKILLing an in-flight model load."
    exit 1
fi
echo "$$" > "${RESUME_LOCKFILE}"
trap 'rm -f "${RESUME_LOCKFILE}"' EXIT

log "Starting Spark vLLM via docker compose..."
ssh "${SPARK_USER}@${SPARK_HOST}" "cd ${SPARK_COMPOSE_DIR} && docker compose up -d"

log "Waiting for Spark Qwen vLLM..."
wait_for_models_endpoint "${SPARK_QWEN_V1_URL}" "Spark Qwen vLLM" 300
healthcheck_chat_completion "${SPARK_QWEN_V1_URL}" "${QWEN_MODEL_ID}" "Spark Qwen vLLM"

log "Switching LiteLLM to agent-mode..."
restart_litellm "agent-mode"

echo ""
log "Spark-local serving is back."
log "  LiteLLM mode: agent-mode"
log "  general -> ${QWEN_MODEL_ID}"

if ! pgrep -f "hermes" > /dev/null 2>&1; then
    warn "Hermes is not running. mba-deploy.sh starts it the first time."
fi

if ! pgrep -f "openclaw" > /dev/null 2>&1; then
    warn "OpenClaw is not running. mba-deploy.sh starts it the first time."
fi
