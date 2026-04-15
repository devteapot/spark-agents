#!/usr/bin/env bash
# spark-setup.sh — Initial setup: install prereqs, configure Ollama, download models
#
# Run this on the DGX Spark (carlid@slopinator-s-1.local) once.
# It will:
#   1. Install huggingface-cli via pipx (shared install under /opt/pipx)
#   2. Create /srv/models (shared-readable, outside /home)
#   3. Download both model GGUFs into /srv/models
#   4. Install a systemd override for Ollama that loads tunables from /etc/ollama.env
#   5. Restart Ollama and build both model tags
#
# The systemd override pins OLLAMA_HOST to 0.0.0.0:11434 and declares
# EnvironmentFile=-/etc/ollama.env. That env file is rewritten dynamically by
# spark-resume.sh / spark-pause.sh, so benchmarking vs agent-serving modes are
# cleanly separated without touching systemd state every cycle.
#
# You will be prompted for your sudo password (once — systemd, /etc writes, pipx).
#
# Prerequisites:
#   - Ollama installed (and running as the `ollama` system user via systemd)
#   - ~100 GB free disk space under /srv
#
# Usage:
#   ssh carlid@slopinator-s-1.local
#   cd ~/spark-agents && ./scripts/spark-setup.sh

set -euo pipefail

MODEL_DIR="/srv/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
ENV_FILE="/etc/ollama.env"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-setup]${NC} $*"; }
err()  { echo -e "${RED}[spark-setup]${NC} $*" >&2; }

# --- 0. Preflight: need sudo ---
log "This script needs sudo for pipx install, /srv/models, and /etc/systemd writes."
sudo -v

# --- 1. Install huggingface-cli via pipx (system-wide) ---
if command -v huggingface-cli > /dev/null 2>&1; then
    log "huggingface-cli already installed at $(command -v huggingface-cli)"
else
    log "Installing huggingface-cli via pipx..."
    if ! command -v pipx > /dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y pipx
    fi
    # Shared install: venv in /opt/pipx, CLI symlinked into /usr/local/bin.
    sudo env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install huggingface-hub
    log "huggingface-cli installed at $(command -v huggingface-cli)"
fi

# --- 2. Create /srv/models (shared-readable) ---
if [ ! -d "${MODEL_DIR}" ]; then
    log "Creating ${MODEL_DIR}..."
    sudo mkdir -p "${MODEL_DIR}"
    sudo chown "$(id -u):$(id -g)" "${MODEL_DIR}"
    sudo chmod 755 "${MODEL_DIR}"
else
    log "${MODEL_DIR} already exists."
fi

mkdir -p "${MODEL_DIR}/supergemma4-26b"
mkdir -p "${MODEL_DIR}/qwen3-coder-next"

# --- 3. Download SuperGemma4 26B Q8_0 ---
log "Downloading SuperGemma4 26B Q8_0 GGUF (~28 GB)..."
if [ -f "${MODEL_DIR}/supergemma4-26b/supergemma4-26b-abliterated-multimodal-Q8_0.gguf" ]; then
    warn "SuperGemma4 GGUF already exists, skipping download."
else
    huggingface-cli download \
        Jiunsong/supergemma4-26b-abliterated-multimodal-gguf-8bit \
        supergemma4-26b-abliterated-multimodal-Q8_0.gguf \
        --local-dir "${MODEL_DIR}/supergemma4-26b"
    log "SuperGemma4 downloaded."
fi

# --- 4. Download Qwen3-Coder-Next Q6_K ---
log "Downloading Qwen3-Coder-Next Q6_K GGUF (~65 GB)..."
if [ -f "${MODEL_DIR}/qwen3-coder-next/Qwen3-Coder-Next-Q6_K.gguf" ]; then
    warn "Qwen3-Coder-Next GGUF already exists, skipping download."
else
    huggingface-cli download \
        unsloth/Qwen3-Coder-Next-GGUF \
        Qwen3-Coder-Next-Q6_K.gguf \
        --local-dir "${MODEL_DIR}/qwen3-coder-next"
    log "Qwen3-Coder-Next downloaded."
fi

# --- 5. Install Ollama systemd override (idempotent) ---
log "Installing Ollama systemd override at ${OVERRIDE_FILE}..."
sudo mkdir -p "${OVERRIDE_DIR}"
sudo tee "${OVERRIDE_FILE}" > /dev/null << 'OVERRIDE_EOF'
# Managed by spark-agents/scripts/spark-setup.sh. Do not hand-edit.
#
# OLLAMA_HOST is pinned here as the baseline (network binding never changes).
# Runtime tunables (NUM_PARALLEL, KV_CACHE_TYPE, FLASH_ATTENTION, ...) live in
# /etc/ollama.env, which is rewritten by spark-resume.sh and spark-pause.sh.
# The leading `-` on EnvironmentFile makes the file optional: if it's absent
# or empty, Ollama starts with stock defaults plus OLLAMA_HOST.
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EnvironmentFile=-/etc/ollama.env
OVERRIDE_EOF

# --- 6. Baseline /etc/ollama.env (empty — stock defaults) ---
if [ ! -f "${ENV_FILE}" ]; then
    log "Creating empty ${ENV_FILE} (benchmark / stock-default mode)..."
    sudo tee "${ENV_FILE}" > /dev/null << 'ENVEOF'
# Ollama runtime tunables. Managed by spark-resume.sh / spark-pause.sh.
# Empty = stock Ollama defaults (used when benchmarking).
ENVEOF
else
    log "${ENV_FILE} already exists, leaving untouched."
fi

# --- 7. Reload systemd and restart Ollama ---
log "Reloading systemd and restarting Ollama..."
sudo systemctl daemon-reload
sudo systemctl restart ollama

# Wait for Ollama to come back online
for i in $(seq 1 20); do
    if curl -sf http://localhost:11434/api/version > /dev/null 2>&1; then
        VERSION=$(curl -sf http://localhost:11434/api/version | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
        log "Ollama is online (v${VERSION})."
        break
    fi
    [ $i -eq 20 ] && { err "Ollama did not come back online within 20s."; err "Check:  journalctl -u ollama -n 50"; exit 1; }
    sleep 1
done

# --- 8. Build Ollama models from Modelfiles ---
log "Building Ollama model: supergemma4:26b-q8..."
ollama create supergemma4:26b-q8 -f "${SCRIPT_DIR}/ollama/Modelfile.supergemma4"
log "supergemma4:26b-q8 created."

log "Building Ollama model: qwen3-coder-next:q6k..."
ollama create qwen3-coder-next:q6k -f "${SCRIPT_DIR}/ollama/Modelfile.qwen3-coder"
log "qwen3-coder-next:q6k created."

# --- 9. Verify ---
echo ""
log "Setup complete. Registered models:"
ollama list | grep -E "(supergemma4|qwen3-coder)" || true

echo ""
log "Ollama config:"
log "  Override:  ${OVERRIDE_FILE}   (static, pins OLLAMA_HOST)"
log "  Env file:  ${ENV_FILE}        (dynamic, rewritten by resume/pause)"
log ""
log "Next steps:"
log "  1. Test a model:   ollama run supergemma4:26b-q8 'hello'"
log "  2. On MBA, run:    spark-resume.sh   (to start agents, applies tunings)"
log "  3. To benchmark:   spark-pause.sh    (clears tunings, restarts Ollama)"
