#!/usr/bin/env bash
# spark-setup.sh - Initial Spark setup for local vLLM serving
#
# Run this on the DGX Spark once. It will:
#   1. Install hf (huggingface-hub CLI) via pipx if needed
#   2. Validate Docker + NVIDIA container runtime availability
#   3. Create /srv/models and download the SuperGemma HF model repo
#   4. Build the Spark-side vLLM container images
#   5. Install the docker-compose.yaml into /srv/spark-agents
#
# Usage:
#   ssh carlid@slopinator-s-1.local
#   cd ~/spark-agents && sudo ./scripts/spark-setup.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="/srv/models"
STATE_DIR="/srv/spark-agents"
SUPERGEMMA_DIR="${MODEL_DIR}/supergemma4-nvfp4"
SUPERGEMMA_CACHE_DIR="${STATE_DIR}/cache/supergemma"
SYSTEMD_DIR="/etc/systemd/system"
DOCKER_BIN="$(command -v docker || true)"
SUPERGEMMA_MODEL_REPO="AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4"
MODELOPT_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/modelopt_patched.py"
SERVING_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/serving_chat_patched.py"
VLLM_BASE_IMAGE="spark-agents/vllm-base:cu132"
SUPERGEMMA_IMAGE="spark-agents/vllm-supergemma:local"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-setup]${NC} $*"; }
err()  { echo -e "${RED}[spark-setup]${NC} $*" >&2; }

build_image() {
    local image="$1"
    local dockerfile="$2"
    shift 2

    log "Building ${image} from ${dockerfile}..."
    sudo "${DOCKER_BIN}" build \
        --network host \
        -t "${image}" \
        -f "${PROJECT_DIR}/${dockerfile}" \
        "$@" \
        "${PROJECT_DIR}"
}

log "This script needs sudo for /srv and Docker image builds."
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

if ! sudo "${DOCKER_BIN}" info > /dev/null 2>&1; then
    err "docker is installed but not usable with sudo on the Spark."
    exit 1
fi

if ! sudo "${DOCKER_BIN}" info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
    warn "Docker does not report an 'nvidia' runtime. GPU containers may fail until the NVIDIA container runtime is configured."
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
    sudo chmod 755 "${MODEL_DIR}"
else
    log "${MODEL_DIR} already exists."
fi

if [ ! -d "${STATE_DIR}" ]; then
    log "Creating ${STATE_DIR}..."
    sudo mkdir -p "${STATE_DIR}"
    sudo chmod 755 "${STATE_DIR}"
fi

sudo mkdir -p "${SUPERGEMMA_DIR}" "${SUPERGEMMA_CACHE_DIR}"
sudo chown -R "$(id -un):$(id -gn)" "${MODEL_DIR}" "${STATE_DIR}"

if [ -f "${SUPERGEMMA_DIR}/config.json" ]; then
    log "${SUPERGEMMA_MODEL_REPO} already present in ${SUPERGEMMA_DIR}."
else
    log "Downloading ${SUPERGEMMA_MODEL_REPO} into ${SUPERGEMMA_DIR}..."
    hf download \
        "${SUPERGEMMA_MODEL_REPO}" \
        --local-dir "${SUPERGEMMA_DIR}"
fi

build_image \
    "${VLLM_BASE_IMAGE}" \
    "docker/vllm-base.Dockerfile"

build_image \
    "${SUPERGEMMA_IMAGE}" \
    "docker/vllm-supergemma.Dockerfile" \
    --build-arg "BASE_IMAGE=${VLLM_BASE_IMAGE}" \
    --build-arg "MODELOPT_PATCH_URL=${MODELOPT_PATCH_URL}" \
    --build-arg "SERVING_PATCH_URL=${SERVING_PATCH_URL}"

# Migrate from legacy systemd units
for legacy_unit in vllm-supergemma.service vllm-coder.service vllm-qwen.service; do
    if [ -f "${SYSTEMD_DIR}/${legacy_unit}" ]; then
        log "Removing legacy ${legacy_unit}..."
        sudo systemctl disable --now "${legacy_unit}" >/dev/null 2>&1 || true
        sudo rm -f "${SYSTEMD_DIR}/${legacy_unit}"
    fi
done
sudo systemctl daemon-reload

log "Installing docker-compose.yaml into ${STATE_DIR}..."
cp "${PROJECT_DIR}/spark/docker-compose.yaml" "${STATE_DIR}/docker-compose.yaml"

echo ""
log "Setup complete."
log "  SuperGemma NVFP4 path: ${SUPERGEMMA_DIR}"
log "  State/cache root:     ${STATE_DIR}"
log "  Compose file:         ${STATE_DIR}/docker-compose.yaml"
log "  Base image:           ${VLLM_BASE_IMAGE}"
log "  SuperGemma image:     ${SUPERGEMMA_IMAGE}"
log ""
log "Next steps:"
log "  1. On MBA, run:    ./scripts/mba-deploy.sh"
log "  2. On MBA, run:    spark-resume.sh   (starts Spark vLLM)"
log "  3. Anytime:        spark-status.sh"
