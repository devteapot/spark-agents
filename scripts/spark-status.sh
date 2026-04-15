#!/usr/bin/env bash
# spark-status.sh — Quick health check: Ollama status, loaded models, agent processes
#
# Run on MBA to check the full stack at a glance.
#
# Usage: ./spark-status.sh

set -uo pipefail

SPARK_HOST="slopinator-s-1.local"
SPARK_OLLAMA="http://${SPARK_HOST}:11434"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

section() { echo -e "\n${CYAN}── $* ──${NC}"; }

# --- Ollama ---
section "Spark Ollama (${SPARK_HOST})"
if curl -sf "${SPARK_OLLAMA}/api/version" > /dev/null 2>&1; then
    VERSION=$(curl -sf "${SPARK_OLLAMA}/api/version" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    echo -e "  Status:  ${GREEN}ONLINE${NC} (v${VERSION})"
else
    echo -e "  Status:  ${RED}OFFLINE${NC}"
    echo "  Cannot reach ${SPARK_OLLAMA}"
fi

# --- Loaded Models ---
section "Loaded Models"
MODELS_JSON=$(curl -sf "${SPARK_OLLAMA}/api/ps" 2>/dev/null || echo '{}')
if echo "${MODELS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('models', [])
if not models:
    print('  No models loaded.')
else:
    for m in models:
        name = m.get('name', '?')
        size = m.get('size', 0)
        size_gb = size / (1024**3)
        print(f'  {name:40s} {size_gb:.1f} GB')
" 2>/dev/null; then
    :
else
    echo "  Could not parse model list."
fi

# --- Available Models ---
section "Available Models (on Spark)"
TAGS_JSON=$(curl -sf "${SPARK_OLLAMA}/api/tags" 2>/dev/null || echo '{}')
echo "${TAGS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('models', [])
if not models:
    print('  No models registered.')
else:
    for m in models:
        name = m.get('name', '?')
        size = m.get('size', 0)
        size_gb = size / (1024**3)
        print(f'  {name:40s} {size_gb:.1f} GB')
" 2>/dev/null || echo "  Could not parse."

# --- Hermes Agent ---
section "Hermes Agent (local)"
if pgrep -f "hermes" > /dev/null 2>&1; then
    PID=$(pgrep -f "hermes" | head -1)
    echo -e "  Status:  ${GREEN}RUNNING${NC} (PID ${PID})"
else
    echo -e "  Status:  ${YELLOW}STOPPED${NC}"
fi

# --- OpenClaw ---
section "OpenClaw (local)"
if pgrep -f "openclaw" > /dev/null 2>&1; then
    PID=$(pgrep -f "openclaw" | head -1)
    echo -e "  Status:  ${GREEN}RUNNING${NC} (PID ${PID})"
else
    echo -e "  Status:  ${YELLOW}STOPPED${NC}"
fi

echo ""
