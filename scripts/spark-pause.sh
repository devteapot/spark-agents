#!/usr/bin/env bash
# spark-pause.sh — Stop agents on MBA, unload models, restore Ollama defaults on Spark
#
# Run this on the MBA before using the Spark for direct inference/benchmarking.
# It gracefully stops both agents, unloads agent models, then restarts Ollama
# on the Spark with CLEAN defaults (no agent overrides) so benchmarks are unaffected.
#
# Usage: spark-pause.sh

set -euo pipefail

SPARK_HOST="slopinator-s-1.local"
SPARK_USER="carlid"
SPARK_OLLAMA="http://${SPARK_HOST}:11434"

SUPERGEMMA_MODEL="supergemma4:26b-q8"
QWEN_MODEL="qwen3-coder-next:q6k"

# Path to the agent env file on the Spark
SPARK_AGENT_ENV="/home/${SPARK_USER}/.ollama/agent.env"
SPARK_OLLAMA_ENV="/home/${SPARK_USER}/.ollama/environment"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-pause]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-pause]${NC} $*"; }
err()  { echo -e "${RED}[spark-pause]${NC} $*" >&2; }

# --- 1. Stop Hermes Agent ---
log "Stopping Hermes Agent..."
if pgrep -f "hermes" > /dev/null 2>&1; then
    hermes stop 2>/dev/null || pkill -f "hermes" 2>/dev/null || true
    sleep 1
    if pgrep -f "hermes" > /dev/null 2>&1; then
        warn "Hermes still running, sending SIGTERM..."
        pkill -TERM -f "hermes" 2>/dev/null || true
    fi
    log "Hermes Agent stopped."
else
    warn "Hermes Agent was not running."
fi

# --- 2. Stop OpenClaw ---
log "Stopping OpenClaw..."
if pgrep -f "openclaw" > /dev/null 2>&1; then
    openclaw stop 2>/dev/null || pkill -f "openclaw" 2>/dev/null || true
    sleep 1
    if pgrep -f "openclaw" > /dev/null 2>&1; then
        warn "OpenClaw still running, sending SIGTERM..."
        pkill -TERM -f "openclaw" 2>/dev/null || true
    fi
    log "OpenClaw stopped."
else
    warn "OpenClaw was not running."
fi

# --- 3. Check Spark Ollama is reachable ---
log "Checking Spark Ollama at ${SPARK_OLLAMA}..."
if ! curl -sf "${SPARK_OLLAMA}/api/version" > /dev/null 2>&1; then
    err "Cannot reach Ollama at ${SPARK_OLLAMA}. Is it running?"
    err "Agents are stopped, but Ollama was not restarted."
    exit 1
fi

# --- 4. Unload agent models ---
log "Unloading ${SUPERGEMMA_MODEL}..."
curl -sf "${SPARK_OLLAMA}/api/generate" \
    -d "{\"model\": \"${SUPERGEMMA_MODEL}\", \"keep_alive\": 0}" \
    > /dev/null 2>&1 && log "  ${SUPERGEMMA_MODEL} unloaded." \
    || warn "  ${SUPERGEMMA_MODEL} was not loaded or failed to unload."

log "Unloading ${QWEN_MODEL}..."
curl -sf "${SPARK_OLLAMA}/api/generate" \
    -d "{\"model\": \"${QWEN_MODEL}\", \"keep_alive\": 0}" \
    > /dev/null 2>&1 && log "  ${QWEN_MODEL} unloaded." \
    || warn "  ${QWEN_MODEL} was not loaded or failed to unload."

# --- 5. Restart Ollama on Spark with CLEAN defaults ---
log "Restarting Ollama on Spark with clean defaults (no agent overrides)..."
ssh "${SPARK_USER}@${SPARK_HOST}" bash -s << 'REMOTE_EOF'
    # Remove the agent environment file if it exists
    # The default Ollama environment file stays untouched
    AGENT_ENV="${HOME}/.ollama/agent.env"
    OLLAMA_ENV="${HOME}/.ollama/environment"

    # If the current environment is the agent one, restore defaults
    if [ -f "${OLLAMA_ENV}" ] && grep -q "OLLAMA_NUM_PARALLEL" "${OLLAMA_ENV}" 2>/dev/null; then
        # Back up and remove agent overrides — restore to bare minimum
        cp "${OLLAMA_ENV}" "${OLLAMA_ENV}.agent.bak"
        # Only keep OLLAMA_HOST so Ollama stays network-accessible
        echo 'OLLAMA_HOST=0.0.0.0' > "${OLLAMA_ENV}"
        echo "[remote] Restored clean Ollama environment (kept OLLAMA_HOST=0.0.0.0)"
    else
        echo "[remote] Ollama environment already clean."
    fi

    # Restart Ollama
    if command -v systemctl > /dev/null 2>&1 && systemctl is-active ollama > /dev/null 2>&1; then
        sudo systemctl restart ollama
        echo "[remote] Ollama restarted via systemctl."
    else
        pkill -f "ollama serve" 2>/dev/null || true
        sleep 1
        nohup ollama serve > /tmp/ollama.log 2>&1 &
        echo "[remote] Ollama restarted manually."
    fi
REMOTE_EOF

# --- 6. Wait for Ollama to come back up ---
log "Waiting for Ollama to restart..."
for i in $(seq 1 15); do
    if curl -sf "${SPARK_OLLAMA}/api/version" > /dev/null 2>&1; then
        log "Ollama is back online."
        break
    fi
    sleep 1
done

# --- 7. Confirm ---
echo ""
log "All done. Agents stopped, models unloaded, Ollama running with clean defaults."
log "The Spark is ready for benchmarking — no agent overrides active."
log ""
log "Current Ollama settings: stock defaults + OLLAMA_HOST=0.0.0.0"
log "Run spark-resume.sh when you're ready to switch back to agents."
