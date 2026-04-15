#!/usr/bin/env bash
# mba-deploy.sh — Deploy Hermes + OpenClaw on the MBA
#
# Run this ON the MBA (sloppy@sloppy-mba.local) from inside the spark-agents directory.
#
# What it does:
#   1. Stops any running Hermes agent
#   2. Backs up existing Hermes config
#   3. Deploys new Hermes config pointing to Spark Ollama
#   4. Installs OpenClaw if not present
#   5. Deploys OpenClaw config pointing to Spark Ollama
#   6. Installs management scripts to ~/bin
#   7. Verifies Spark Ollama connectivity
#
# Usage:
#   cd spark-agents
#   ./scripts/mba-deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SPARK_HOST="slopinator-s-1.local"
SPARK_OLLAMA="http://${SPARK_HOST}:11434"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()     { echo -e "${RED}[deploy]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# --- Preflight: check we're in the right place ---
if [ ! -f "${PROJECT_DIR}/hermes/cli-config.yaml" ] || [ ! -f "${PROJECT_DIR}/openclaw/config.json" ]; then
    err "Cannot find config files. Run this from inside the spark-agents directory:"
    err "  cd spark-agents && ./scripts/mba-deploy.sh"
    exit 1
fi

section "1/7  Stopping existing Hermes Agent"
if pgrep -f "hermes" > /dev/null 2>&1; then
    hermes stop 2>/dev/null || true
    sleep 1
    pkill -f "hermes" 2>/dev/null || true
    sleep 1
    if pgrep -f "hermes" > /dev/null 2>&1; then
        pkill -9 -f "hermes" 2>/dev/null || true
    fi
    log "Hermes stopped."
else
    log "Hermes was not running."
fi

section "2/7  Backing up existing Hermes config"
if [ -d "${HOME}/.hermes" ]; then
    BACKUP="${HOME}/.hermes.bak.$(date +%Y%m%d_%H%M%S)"
    cp -r "${HOME}/.hermes" "${BACKUP}"
    log "Backed up to ${BACKUP}"
else
    log "No existing ~/.hermes found, nothing to back up."
fi

section "3/7  Deploying Hermes config"
mkdir -p "${HOME}/.hermes"
cp "${PROJECT_DIR}/hermes/cli-config.yaml" "${HOME}/.hermes/cli-config.yaml"
log "Installed ~/.hermes/cli-config.yaml"
echo "  Provider:  Ollama @ ${SPARK_OLLAMA}"
echo "  Primary:   supergemma4:26b-q8"
echo "  Coding:    qwen3-coder-next:q6k"

section "4/7  Checking OpenClaw installation"
if command -v openclaw > /dev/null 2>&1; then
    CLAW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
    log "OpenClaw already installed (${CLAW_VERSION})"
else
    warn "OpenClaw not found. Attempting install..."
    if command -v npm > /dev/null 2>&1; then
        npm install -g openclaw@latest
        openclaw onboard --install-daemon
        log "OpenClaw installed via npm."
    elif command -v brew > /dev/null 2>&1; then
        brew install openclaw
        log "OpenClaw installed via Homebrew."
    else
        err "Cannot install OpenClaw: neither npm nor brew found."
        err "Install manually: npm install -g openclaw@latest"
        err "Continuing with remaining setup..."
    fi
fi

section "5/7  Deploying OpenClaw config"
mkdir -p "${HOME}/.openclaw"

# Stop OpenClaw if running
if pgrep -f "openclaw" > /dev/null 2>&1; then
    openclaw stop 2>/dev/null || pkill -f "openclaw" 2>/dev/null || true
    log "Stopped running OpenClaw."
fi

# Back up existing config
if [ -f "${HOME}/.openclaw/config.json" ]; then
    cp "${HOME}/.openclaw/config.json" "${HOME}/.openclaw/config.json.bak.$(date +%Y%m%d_%H%M%S)"
    log "Backed up existing OpenClaw config."
fi

cp "${PROJECT_DIR}/openclaw/config.json" "${HOME}/.openclaw/config.json"
log "Installed ~/.openclaw/config.json"

section "6/7  Installing management scripts"
mkdir -p "${HOME}/bin"

for script in spark-pause.sh spark-resume.sh spark-status.sh; do
    cp "${PROJECT_DIR}/scripts/${script}" "${HOME}/bin/${script}"
    chmod +x "${HOME}/bin/${script}"
done
log "Installed to ~/bin: spark-pause.sh, spark-resume.sh, spark-status.sh"

# Ensure ~/bin is in PATH
if [[ ":$PATH:" != *":${HOME}/bin:"* ]]; then
    SHELL_RC="${HOME}/.zshrc"
    [ -f "${SHELL_RC}" ] || SHELL_RC="${HOME}/.bashrc"
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "${SHELL_RC}" 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "${SHELL_RC}"
        log "Added ~/bin to PATH in ${SHELL_RC}"
        warn "Run 'source ${SHELL_RC}' or open a new terminal for PATH to take effect."
    fi
fi

section "7/7  Verifying Spark Ollama connectivity"
echo -n "  Reaching ${SPARK_OLLAMA}... "
if curl -sf --connect-timeout 5 "${SPARK_OLLAMA}/api/version" > /dev/null 2>&1; then
    VERSION=$(curl -sf "${SPARK_OLLAMA}/api/version" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    echo -e "${GREEN}OK${NC} (Ollama v${VERSION})"

    echo ""
    log "Checking loaded models..."
    curl -sf "${SPARK_OLLAMA}/api/tags" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('models', [])
if not models:
    print('  No models registered yet. Run spark-setup.sh on the Spark first.')
else:
    for m in models:
        name = m.get('name', '?')
        size = m.get('size', 0)
        size_gb = size / (1024**3)
        print(f'  {name:40s} {size_gb:.1f} GB')
" 2>/dev/null || echo "  Could not parse model list."
else
    echo -e "${YELLOW}UNREACHABLE${NC}"
    warn "Cannot reach Spark Ollama at ${SPARK_OLLAMA}"
    warn "This is expected if the Spark isn't running Ollama right now."
    warn "When ready, run spark-setup.sh on the Spark, then spark-resume.sh here."
fi

# --- Summary ---
echo ""
echo -e "${CYAN}━━━ Deployment Complete ━━━${NC}"
echo ""
echo "  Files deployed:"
echo "    ~/.hermes/cli-config.yaml     Hermes → Spark Ollama"
echo "    ~/.openclaw/config.json       OpenClaw → Spark Ollama"
echo "    ~/bin/spark-pause.sh          Stop agents, unload models"
echo "    ~/bin/spark-resume.sh         Load models, start agents"
echo "    ~/bin/spark-status.sh         Health check"
echo ""
echo "  Next steps:"
echo "    1. On Spark: run spark-setup.sh to download models + configure Ollama"
echo "    2. On MBA:   run spark-resume.sh to preload models + start agents"
echo "    3. Anytime:  run spark-status.sh to check everything"
echo ""
echo "  To pause for benchmarking:  spark-pause.sh"
echo "  To resume agents:           spark-resume.sh"
echo ""
