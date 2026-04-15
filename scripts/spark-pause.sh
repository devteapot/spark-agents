#!/usr/bin/env bash
# spark-pause.sh - Switch LiteLLM to hosted routing, then stop Spark-local vLLM services

set -euo pipefail

SCRIPT_LABEL="spark-pause"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

require_command ssh

ensure_runtime_dirs
ensure_litellm_installed
require_openrouter_api_key > /dev/null

log "Switching LiteLLM to benchmark-mode first..."
restart_litellm "benchmark-mode"

log "Stopping Spark vLLM services..."
spark_remote_sudo <<'REMOTE_EOF'
systemctl stop vllm-supergemma.service vllm-coder.service
systemctl stop vllm-qwen.service >/dev/null 2>&1 || true
REMOTE_EOF

echo ""
log "Benchmark mode is active."
log "  LiteLLM mode: benchmark-mode"
log "  general -> ${GENERAL_CLOUD_MODEL_ID}"
log "  coder   -> ${CODER_CLOUD_MODEL_ID}"
log "  Hermes and OpenClaw were left running."
