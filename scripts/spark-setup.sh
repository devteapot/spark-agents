#!/usr/bin/env bash
# spark-setup.sh — Initial setup: download models and register with Ollama
#
# Run this on the DGX Spark (carlid@slopinator-s-1.local) once.
# It downloads both model GGUFs and registers them with Ollama.
#
# IMPORTANT: This script does NOT modify Ollama's global environment.
# Agent-specific Ollama settings (NUM_PARALLEL, KV_CACHE_TYPE, etc.) are applied
# dynamically by spark-resume.sh and removed by spark-pause.sh, so your
# benchmarking workflow is never affected.
#
# Prerequisites:
#   - Ollama installed on the Spark
#   - huggingface-cli installed (pip install huggingface-hub)
#   - ~100GB free disk space for model files
#
# Usage: ssh carlid@slopinator-s-1.local
#        cd ~/spark-agents && ./scripts/spark-setup.sh

set -euo pipefail

MODEL_DIR="${HOME}/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-setup]${NC} $*"; }
err()  { echo -e "${RED}[spark-setup]${NC} $*" >&2; }

# --- 1. Create model directories ---
log "Creating model directories..."
mkdir -p "${MODEL_DIR}/supergemma4-26b"
mkdir -p "${MODEL_DIR}/qwen3-coder-next"

# --- 2. Download SuperGemma4 26B Q8_0 ---
log "Downloading SuperGemma4 26B Q8_0 GGUF (~28GB)..."
if [ -f "${MODEL_DIR}/supergemma4-26b/supergemma4-26b-abliterated-multimodal-Q8_0.gguf" ]; then
    warn "SuperGemma4 GGUF already exists, skipping download."
else
    huggingface-cli download \
        Jiunsong/supergemma4-26b-abliterated-multimodal-gguf-8bit \
        supergemma4-26b-abliterated-multimodal-Q8_0.gguf \
        --local-dir "${MODEL_DIR}/supergemma4-26b"
    log "SuperGemma4 downloaded."
fi

# --- 3. Download Qwen3-Coder-Next Q6_K ---
log "Downloading Qwen3-Coder-Next Q6_K GGUF (~65GB)..."
if [ -f "${MODEL_DIR}/qwen3-coder-next/Qwen3-Coder-Next-Q6_K.gguf" ]; then
    warn "Qwen3-Coder-Next GGUF already exists, skipping download."
else
    huggingface-cli download \
        unsloth/Qwen3-Coder-Next-GGUF \
        Qwen3-Coder-Next-Q6_K.gguf \
        --local-dir "${MODEL_DIR}/qwen3-coder-next"
    log "Qwen3-Coder-Next downloaded."
fi

# --- 4. Ensure OLLAMA_HOST allows network access ---
# Only set the host binding — no agent-specific tuning.
# Agent settings are managed dynamically by spark-resume.sh / spark-pause.sh.
OLLAMA_ENV="${HOME}/.ollama/environment"
mkdir -p "${HOME}/.ollama"

if [ -f "${OLLAMA_ENV}" ]; then
    if grep -q "OLLAMA_HOST=0.0.0.0" "${OLLAMA_ENV}" 2>/dev/null; then
        log "OLLAMA_HOST=0.0.0.0 already set."
    else
        warn "Existing ${OLLAMA_ENV} found. Adding OLLAMA_HOST=0.0.0.0"
        echo 'OLLAMA_HOST=0.0.0.0' >> "${OLLAMA_ENV}"
    fi
else
    echo 'OLLAMA_HOST=0.0.0.0' > "${OLLAMA_ENV}"
    log "Created ${OLLAMA_ENV} with OLLAMA_HOST=0.0.0.0"
fi

# --- 5. Build Ollama models from Modelfiles ---
log "Building Ollama model: supergemma4:26b-q8..."
ollama create supergemma4:26b-q8 -f "${SCRIPT_DIR}/ollama/Modelfile.supergemma4"
log "supergemma4:26b-q8 created."

log "Building Ollama model: qwen3-coder-next:q6k..."
ollama create qwen3-coder-next:q6k -f "${SCRIPT_DIR}/ollama/Modelfile.qwen3-coder"
log "qwen3-coder-next:q6k created."

# --- 6. Verify ---
echo ""
log "Setup complete. Registered models:"
ollama list | grep -E "(supergemma4|qwen3-coder)"

echo ""
log "Ollama global config: ONLY OLLAMA_HOST=0.0.0.0 (your benchmarks are unaffected)"
log "Agent settings (NUM_PARALLEL, KV_CACHE, etc.) are applied/removed dynamically"
log "by spark-resume.sh and spark-pause.sh from the MBA."
echo ""
log "Next steps:"
log "  1. Restart Ollama if needed:  sudo systemctl restart ollama"
log "  2. Test a model:              ollama run supergemma4:26b-q8 'hello'"
log "  3. On MBA, run:               spark-resume.sh   (to start agents)"
log "  4. To benchmark:              spark-pause.sh     (restores clean defaults)"
