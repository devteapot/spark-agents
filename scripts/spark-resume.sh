#!/usr/bin/env bash
# spark-resume.sh — Apply agent Ollama tunings on Spark, preload models, start agents on MBA
#
# Run this on the MBA when you're ready to switch from direct inference/benchmarking
# back to agent serving. It SSHes to the Spark, rewrites /etc/ollama.env with
# agent-optimized settings, restarts Ollama, preloads both models, then starts
# Hermes and OpenClaw locally.
#
# /etc/ollama.env is loaded via the systemd override installed by spark-setup.sh,
# so nothing else in systemd needs touching. OLLAMA_HOST stays pinned in
# override.conf and is never rewritten.
#
# The sudo calls on the Spark need a TTY, so ssh uses -tt. You'll be prompted
# for your Spark sudo password once.
#
# Usage: spark-resume.sh

set -euo pipefail

SPARK_HOST="slopinator-s-1.local"
SPARK_USER="carlid"
SPARK_OLLAMA="http://${SPARK_HOST}:11434"

SUPERGEMMA_MODEL="supergemma4:26b-q8"
QWEN_MODEL="qwen3-coder-next:q6k"

# Max seconds to wait for a model to load
LOAD_TIMEOUT=120

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-resume]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-resume]${NC} $*"; }
err()  { echo -e "${RED}[spark-resume]${NC} $*" >&2; }

# --- 1. Apply agent tunings on Spark and restart Ollama ---
log "Writing agent /etc/ollama.env on Spark and restarting Ollama..."
ssh -tt "${SPARK_USER}@${SPARK_HOST}" bash -s << 'REMOTE_EOF'
set -euo pipefail

sudo tee /etc/ollama.env > /dev/null << 'ENVEOF'
# Managed by spark-resume.sh — agent serving mode.
# Two concurrent slots (one per agent), both models pinned, Q8 KV cache, flash attn.
OLLAMA_NUM_PARALLEL=2
OLLAMA_MAX_LOADED_MODELS=2
OLLAMA_KV_CACHE_TYPE=q8_0
OLLAMA_FLASH_ATTENTION=1
ENVEOF

echo "[remote] /etc/ollama.env updated with agent tunings."
sudo systemctl restart ollama
echo "[remote] Ollama restarted."
REMOTE_EOF

# --- 2. Wait for Ollama to come back up ---
log "Waiting for Ollama to come online..."
for i in $(seq 1 20); do
    if curl -sf "${SPARK_OLLAMA}/api/version" > /dev/null 2>&1; then
        VERSION=$(curl -sf "${SPARK_OLLAMA}/api/version" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
        log "Ollama is online (v${VERSION}) with agent tunings."
        break
    fi
    if [ $i -eq 20 ]; then
        err "Ollama did not come back online within 20s."
        err "Check manually: ssh ${SPARK_USER}@${SPARK_HOST} 'systemctl status ollama'"
        exit 1
    fi
    sleep 1
done

# --- 3. Preload models ---
preload_model() {
    local model="$1"
    log "Preloading ${model}..."

    # keep_alive=-1 keeps the model resident indefinitely
    curl -sf "${SPARK_OLLAMA}/api/generate" \
        -d "{\"model\": \"${model}\", \"prompt\": \"hello\", \"keep_alive\": -1}" \
        > /dev/null 2>&1 &
    local curl_pid=$!

    local elapsed=0
    while [ $elapsed -lt $LOAD_TIMEOUT ]; do
        if curl -sf "${SPARK_OLLAMA}/api/ps" 2>/dev/null | grep -q "${model}"; then
            echo ""
            log "  ${model} loaded successfully."
            wait $curl_pid 2>/dev/null || true
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -ne "\r  Waiting for ${model}... ${elapsed}s"
    done

    echo ""
    warn "  ${model} did not appear in loaded models within ${LOAD_TIMEOUT}s."
    warn "  It may still be loading. Check: curl ${SPARK_OLLAMA}/api/ps"
    wait $curl_pid 2>/dev/null || true
    return 1
}

preload_model "${SUPERGEMMA_MODEL}"
preload_model "${QWEN_MODEL}"

# --- 4. Verify both loaded ---
echo ""
log "Currently loaded models:"
curl -sf "${SPARK_OLLAMA}/api/ps" 2>/dev/null | python3 -c "
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
" 2>/dev/null || curl -sf "${SPARK_OLLAMA}/api/ps" 2>/dev/null
echo ""

# --- 5. Start Hermes Agent ---
log "Starting Hermes Agent..."
if pgrep -f "hermes" > /dev/null 2>&1; then
    warn "Hermes Agent is already running."
else
    nohup hermes start > /tmp/hermes-agent.log 2>&1 &
    sleep 2
    if pgrep -f "hermes" > /dev/null 2>&1; then
        log "Hermes Agent started. Log: /tmp/hermes-agent.log"
    else
        err "Hermes Agent failed to start. Check /tmp/hermes-agent.log"
    fi
fi

# --- 6. Start OpenClaw ---
log "Starting OpenClaw..."
if pgrep -f "openclaw" > /dev/null 2>&1; then
    warn "OpenClaw is already running."
else
    nohup openclaw start > /tmp/openclaw.log 2>&1 &
    sleep 2
    if pgrep -f "openclaw" > /dev/null 2>&1; then
        log "OpenClaw started. Log: /tmp/openclaw.log"
    else
        err "OpenClaw failed to start. Check /tmp/openclaw.log"
    fi
fi

# --- 7. Done ---
echo ""
log "All systems go."
log "  Ollama tunings: NUM_PARALLEL=2, MAX_LOADED=2, KV_CACHE=q8_0, FLASH_ATTN=1"
log "  Hermes Agent → ${SUPERGEMMA_MODEL} (general intelligence)"
log "  OpenClaw     → ${SUPERGEMMA_MODEL} (primary) / ${QWEN_MODEL} (coding)"
log "  Spark Ollama → ${SPARK_OLLAMA}"
