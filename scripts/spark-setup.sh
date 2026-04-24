#!/usr/bin/env bash
# spark-setup.sh - Initial Spark setup for local llama.cpp serving
#
# Run this on the DGX Spark once. It will:
#   1. Install hf (huggingface-hub CLI) via pipx if needed
#   2. Validate Docker + NVIDIA container runtime availability
#   3. Create /models/27b-q4 and download Qwen3.6-27B-Q4_K_M.gguf
#   4. Pull the upstream ghcr.io/ggml-org/llama.cpp:server-cuda image
#   5. Remove legacy vLLM containers (keeps their images on disk for rollback)
#
# Usage:
#   ssh carlid@slopinator-s-1.local
#   cd ~/spark-agents && ./scripts/spark-setup.sh

set -euo pipefail

MODEL_DIR="/models/27b-q4"
GGUF_REPO="unsloth/Qwen3.6-27B-GGUF"
GGUF_FILE="Qwen3.6-27B-Q4_K_M.gguf"
LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
SYSTEMD_DIR="/etc/systemd/system"
DOCKER_BIN="$(command -v docker || true)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-setup]${NC} $*"; }
err()  { echo -e "${RED}[spark-setup]${NC} $*" >&2; }

log "This script needs sudo for /models and to clean up legacy containers/units."
sudo -v

if ! command -v python3 > /dev/null 2>&1; then
    err "python3 is required on the Spark."
    exit 1
fi

if [ -z "${DOCKER_BIN}" ]; then
    err "docker is required on the Spark. Install Docker Engine with the NVIDIA container runtime first."
    exit 1
fi

log "Ensuring system prerequisites are installed..."
sudo apt-get update -qq
sudo apt-get install -y curl python3-venv pipx

if ! "${DOCKER_BIN}" info > /dev/null 2>&1; then
    err "docker is installed but not usable for the current user. Add the user to the 'docker' group."
    exit 1
fi

if ! "${DOCKER_BIN}" info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
    warn "Docker does not report an 'nvidia' runtime. Run:"
    warn "    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    warn "GPU containers will fall back to CPU until this is configured."
fi

if command -v hf > /dev/null 2>&1; then
    log "hf already installed at $(command -v hf)"
else
    log "Installing hf via pipx..."
    sudo env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install huggingface-hub
    log "hf installed at $(command -v hf)"
fi

if [ ! -d "${MODEL_DIR}" ]; then
    log "Creating ${MODEL_DIR}..."
    sudo mkdir -p "${MODEL_DIR}"
fi
sudo chown -R "$(id -un):$(id -gn)" "$(dirname "${MODEL_DIR}")"
sudo chmod 755 "$(dirname "${MODEL_DIR}")" "${MODEL_DIR}"

if [ -f "${MODEL_DIR}/${GGUF_FILE}" ]; then
    log "${GGUF_FILE} already present in ${MODEL_DIR}."
else
    log "Downloading ${GGUF_REPO}/${GGUF_FILE} into ${MODEL_DIR}..."
    hf download \
        "${GGUF_REPO}" \
        "${GGUF_FILE}" \
        --local-dir "${MODEL_DIR}"
fi

log "Pulling ${LLAMA_IMAGE}..."
"${DOCKER_BIN}" pull "${LLAMA_IMAGE}"

# Stop + remove legacy vLLM containers (images stay on disk for rollback).
for legacy_container in spark-vllm-qwen spark-vllm-supergemma spark-vllm-coder; do
    if "${DOCKER_BIN}" ps -a --format '{{.Names}}' | grep -qx "${legacy_container}"; then
        log "Removing legacy container ${legacy_container}..."
        "${DOCKER_BIN}" rm -f "${legacy_container}" > /dev/null
    fi
done

# Migrate from legacy systemd units if any remain.
for legacy_unit in vllm-supergemma.service vllm-coder.service vllm-qwen.service; do
    if [ -f "${SYSTEMD_DIR}/${legacy_unit}" ]; then
        log "Removing legacy ${legacy_unit}..."
        sudo systemctl disable --now "${legacy_unit}" >/dev/null 2>&1 || true
        sudo rm -f "${SYSTEMD_DIR}/${legacy_unit}"
    fi
done
sudo systemctl daemon-reload

echo ""
log "Setup complete."
log "  Model path:       ${MODEL_DIR}/${GGUF_FILE}"
log "  llama.cpp image:  ${LLAMA_IMAGE}"
log ""
log "Next steps:"
log "  1. On MBA, run:  ./scripts/mba-deploy.sh   (staging + LiteLLM)"
log "  2. On MBA, run:  spark-resume.sh           (starts Spark llama.cpp)"
log "  3. Anytime:      spark-status.sh"
