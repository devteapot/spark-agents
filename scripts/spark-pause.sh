#!/usr/bin/env bash
# spark-pause.sh - Switch LiteLLM to hosted routing, then stop Spark vLLM

set -euo pipefail

SCRIPT_LABEL="spark-pause"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

require_command ssh

ensure_runtime_dirs
ensure_litellm_installed
require_openrouter_api_key > /dev/null

log "Switching LiteLLM to offload-mode first..."
restart_litellm "offload-mode"

log "Stopping Spark vLLM..."
ssh "${SPARK_USER}@${SPARK_HOST}" "cd ${SPARK_COMPOSE_DIR} && sudo docker compose down"

echo ""
log "Offload mode is active. Spark GPU is free for non-agent compute."
log "  LiteLLM mode: offload-mode"
log "  general -> ${GENERAL_CLOUD_MODEL_ID}"
log "  Hermes and OpenClaw were left running."
