#!/usr/bin/env bash
# spark-status.sh - Health check for LiteLLM, Spark vLLM services, and agent processes

set -uo pipefail

SCRIPT_LABEL="spark-status"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/spark-common.sh"

require_command curl

section "Router"
echo "  Active mode:  $(current_router_mode)"
if litellm_is_running; then
    echo -e "  LiteLLM:      ${GREEN}RUNNING${NC} (PID $(litellm_pid))"
else
    echo -e "  LiteLLM:      ${YELLOW}STOPPED${NC}"
fi

if MODELS_JSON="$(curl -sf "${LITELLM_V1_URL}/models" 2>/dev/null)"; then
    echo -e "  Endpoint:     ${GREEN}ONLINE${NC} (${LITELLM_V1_URL})"
    print_openai_models "${MODELS_JSON}"
else
    echo -e "  Endpoint:     ${RED}OFFLINE${NC} (${LITELLM_V1_URL})"
fi

section "Spark vLLM"
if MODELS_JSON="$(curl -sf "${SPARK_SUPERGEMMA_V1_URL}/models" 2>/dev/null)"; then
    echo -e "  SuperGemma:   ${GREEN}ONLINE${NC} (${SPARK_SUPERGEMMA_V1_URL})"
    print_openai_models "${MODELS_JSON}"
else
    echo -e "  SuperGemma:   ${YELLOW}OFFLINE${NC} (${SPARK_SUPERGEMMA_V1_URL})"
fi

if MODELS_JSON="$(curl -sf "${SPARK_CODER_V1_URL}/models" 2>/dev/null)"; then
    echo -e "  Coder:        ${GREEN}ONLINE${NC} (${SPARK_CODER_V1_URL})"
    print_openai_models "${MODELS_JSON}"
else
    echo -e "  Coder:        ${YELLOW}OFFLINE${NC} (${SPARK_CODER_V1_URL})"
fi

section "Agents"
if pgrep -f "hermes" > /dev/null 2>&1; then
    echo -e "  Hermes:       ${GREEN}RUNNING${NC} (PID $(pgrep -f "hermes" | head -1))"
else
    echo -e "  Hermes:       ${YELLOW}STOPPED${NC}"
fi

if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  OpenClaw:     ${GREEN}RUNNING${NC} (PID $(pgrep -f "openclaw" | head -1))"
else
    echo -e "  OpenClaw:     ${YELLOW}STOPPED${NC}"
fi

echo ""
