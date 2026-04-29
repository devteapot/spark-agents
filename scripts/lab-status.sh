#!/usr/bin/env bash
# lab-status.sh - Health check for LiteLLM, Spark vLLM, and agent processes

set -uo pipefail

SCRIPT_LABEL="lab-status"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lab-common.sh"

require_command curl

section "Router"
echo "  Active mode:  $(current_router_mode)"
if litellm_is_running; then
    echo -e "  LiteLLM:      ${GREEN}RUNNING${NC}"
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
if MODELS_JSON="$(curl -sf "${SPARK_QWEN_V1_URL}/models" 2>/dev/null)"; then
    echo -e "  Qwen:         ${GREEN}ONLINE${NC} (${SPARK_QWEN_V1_URL})"
    print_openai_models "${MODELS_JSON}"
else
    echo -e "  Qwen:         ${YELLOW}OFFLINE${NC} (${SPARK_QWEN_V1_URL})"
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
