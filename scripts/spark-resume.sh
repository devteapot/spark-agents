#!/usr/bin/env bash
# spark-resume.sh - Restore Spark-local vLLM serving and switch LiteLLM to agent-mode

set -euo pipefail

SCRIPT_LABEL="spark-resume"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

require_command curl
require_command ssh
require_command python3

ensure_runtime_dirs
ensure_litellm_installed

log "Starting Spark Qwen vLLM first..."
spark_remote_sudo <<'REMOTE_EOF'
systemctl reset-failed vllm-qwen.service vllm-supergemma.service || true
systemctl start vllm-qwen.service
REMOTE_EOF

log "Waiting for Spark Qwen vLLM..."
wait_for_models_endpoint "${SPARK_QWEN_V1_URL}" "Spark Qwen vLLM" 300
healthcheck_tool_call "${SPARK_QWEN_V1_URL}" "${QWEN_MODEL_ID}" "Spark Qwen vLLM"

log "Starting Spark SuperGemma vLLM..."
spark_remote_sudo <<'REMOTE_EOF'
systemctl start vllm-supergemma.service
REMOTE_EOF

log "Waiting for Spark SuperGemma vLLM..."
wait_for_models_endpoint "${SPARK_SUPERGEMMA_V1_URL}" "Spark SuperGemma vLLM" 300
healthcheck_chat_completion "${SPARK_SUPERGEMMA_V1_URL}" "${SUPERGEMMA_MODEL_ID}" "Spark SuperGemma vLLM"

log "Switching LiteLLM to agent-mode..."
restart_litellm "agent-mode"

echo ""
log "Spark-local serving is back."
log "  LiteLLM mode: agent-mode"
log "  general -> ${SUPERGEMMA_MODEL_ID}"
log "  coder   -> ${QWEN_MODEL_ID}"

if ! pgrep -f "hermes" > /dev/null 2>&1; then
    warn "Hermes is not running. mba-deploy.sh starts it the first time."
fi

if ! pgrep -f "openclaw" > /dev/null 2>&1; then
    warn "OpenClaw is not running. mba-deploy.sh starts it the first time."
fi
