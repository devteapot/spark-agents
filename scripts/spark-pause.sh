#!/usr/bin/env bash
# spark-pause.sh — Stop agents on MBA, unload models, clear agent tunings on Spark
#
# Run this on the MBA before using the Spark for direct inference/benchmarking.
# It gracefully stops both agents, unloads the agent models, then SSHes to the
# Spark, clears /etc/ollama.env (agent tunings), and restarts Ollama so it comes
# back up with stock defaults + OLLAMA_HOST (from the systemd override).
#
# The systemd override itself is never touched — it was installed once by
# spark-setup.sh and declares EnvironmentFile=-/etc/ollama.env, so emptying
# that one file is enough to revert to clean defaults.
#
# The sudo calls on the Spark need a TTY, so ssh uses -tt. You'll be prompted
# for your Spark sudo password once.
#
# Usage: spark-pause.sh

set -euo pipefail

SPARK_HOST="slopinator-s-1.local"
SPARK_USER="carlid"
SPARK_OLLAMA="http://${SPARK_HOST}:11434"

SUPERGEMMA_MODEL="supergemma4:26b-q8"
QWEN_MODEL="qwen3-coder-next:q6k"

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

# --- 5. Clear /etc/ollama.env on Spark and restart Ollama ---
log "Clearing agent tunings from /etc/ollama.env and restarting Ollama..."
ssh -tt "${SPARK_USER}@${SPARK_HOST}" bash -s << 'REMOTE_EOF'
set -euo pipefail

sudo tee /etc/ollama.env > /dev/null << 'ENVEOF'
# Managed by spark-pause.sh — benchmark / stock-default mode.
# Empty means Ollama uses stock defaults (OLLAMA_HOST stays pinned in override.conf).
ENVEOF

echo "[remote] /etc/ollama.env cleared (stock defaults)."
sudo systemctl restart ollama
echo "[remote] Ollama restarted."
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
log "All done. Agents stopped, models unloaded, Ollama running with stock defaults."
log "The Spark is ready for benchmarking — no agent overrides active."
log ""
log "Current config:"
log "  Override (static):  OLLAMA_HOST=0.0.0.0:11434"
log "  Env file (cleared): /etc/ollama.env is empty"
log ""
log "Run spark-resume.sh when you're ready to switch back to agents."
