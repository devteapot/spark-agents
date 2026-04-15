#!/usr/bin/env bash
# spark-setup.sh - Initial Spark setup for local vLLM serving
#
# Run this on the DGX Spark once. It will:
#   1. Install hf (huggingface-hub CLI) via pipx if needed
#   2. Validate Docker + NVIDIA container runtime availability
#   3. Create /srv/models and download the two HF model repos
#   4. Build the Spark-side vLLM container images
#   5. Install the Spark-side systemd units for SuperGemma and coder
#   6. Enable the units so spark-resume.sh / spark-pause.sh can manage them
#
# Usage:
#   ssh carlid@slopinator-s-1.local
#   cd ~/spark-agents && ./scripts/spark-setup.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="/srv/models"
STATE_DIR="/srv/spark-agents"
SUPERGEMMA_DIR="${MODEL_DIR}/supergemma4-nvfp4"
CODER_DIR="${MODEL_DIR}/nemotron-super-nvfp4"
SUPERGEMMA_CACHE_DIR="${STATE_DIR}/cache/supergemma"
CODER_CACHE_DIR="${STATE_DIR}/cache/coder"
SYSTEMD_DIR="/etc/systemd/system"
DOCKER_BIN="$(command -v docker || true)"
TORCH_CUDA_INDEX_URL="https://download.pytorch.org/whl/cu130"
VLLM_CUDA_WHEEL_URL="https://wheels.vllm.ai/2a69949bdadf0e8942b7a1619b229cb475beef20/vllm-0.19.0%2Bcu130-cp38-abi3-manylinux_2_35_aarch64.whl"
SUPERGEMMA_MODEL_REPO="AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4"
CODER_MODEL_REPO="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"
MODELOPT_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/modelopt_patched.py"
SERVING_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/serving_chat_patched.py"
VLLM_BASE_IMAGE="spark-agents/vllm-base:cu130"
SUPERGEMMA_IMAGE="spark-agents/vllm-supergemma:local"
CODER_IMAGE="spark-agents/vllm-coder:local"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[spark-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[spark-setup]${NC} $*"; }
err()  { echo -e "${RED}[spark-setup]${NC} $*" >&2; }

render_template() {
    local template="$1"
    local destination="$2"
    local tmp_file
    tmp_file="$(mktemp)"

    TEMPLATE_PATH="${template}" \
    DOCKER_BIN_RENDER="${DOCKER_BIN}" \
    SUPERGEMMA_DIR_RENDER="${SUPERGEMMA_DIR}" \
    SUPERGEMMA_CACHE_DIR_RENDER="${SUPERGEMMA_CACHE_DIR}" \
    SUPERGEMMA_IMAGE_RENDER="${SUPERGEMMA_IMAGE}" \
    CODER_DIR_RENDER="${CODER_DIR}" \
    CODER_CACHE_DIR_RENDER="${CODER_CACHE_DIR}" \
    CODER_IMAGE_RENDER="${CODER_IMAGE}" \
    python3 - <<'PY' > "${tmp_file}"
import os
from pathlib import Path

text = Path(os.environ["TEMPLATE_PATH"]).read_text()
replacements = {
    "__DOCKER_BIN__": os.environ["DOCKER_BIN_RENDER"],
    "__SUPERGEMMA_MODEL_PATH__": os.environ["SUPERGEMMA_DIR_RENDER"],
    "__SUPERGEMMA_CACHE_DIR__": os.environ["SUPERGEMMA_CACHE_DIR_RENDER"],
    "__SUPERGEMMA_IMAGE__": os.environ["SUPERGEMMA_IMAGE_RENDER"],
    "__CODER_MODEL_PATH__": os.environ["CODER_DIR_RENDER"],
    "__CODER_CACHE_DIR__": os.environ["CODER_CACHE_DIR_RENDER"],
    "__CODER_IMAGE__": os.environ["CODER_IMAGE_RENDER"],
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
print(text, end="")
PY

    sudo install -m 0644 "${tmp_file}" "${destination}"
    rm -f "${tmp_file}"
}

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

log "This script needs sudo for /srv, Docker image builds, and /etc/systemd writes."
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

sudo mkdir -p "${SUPERGEMMA_DIR}" "${CODER_DIR}" "${SUPERGEMMA_CACHE_DIR}" "${CODER_CACHE_DIR}"
sudo chown -R "$(id -un):$(id -gn)" "${MODEL_DIR}" "${STATE_DIR}"

log "Downloading ${SUPERGEMMA_MODEL_REPO} into ${SUPERGEMMA_DIR}..."
hf download \
    "${SUPERGEMMA_MODEL_REPO}" \
    --local-dir "${SUPERGEMMA_DIR}"

log "Downloading ${CODER_MODEL_REPO} into ${CODER_DIR}..."
hf download \
    "${CODER_MODEL_REPO}" \
    --local-dir "${CODER_DIR}"

if [ ! -f "${CODER_DIR}/super_v3_reasoning_parser.py" ]; then
    err "Expected reasoning parser not found at ${CODER_DIR}/super_v3_reasoning_parser.py after download."
    exit 1
fi

build_image \
    "${VLLM_BASE_IMAGE}" \
    "docker/vllm-base.Dockerfile" \
    --build-arg "TORCH_CUDA_INDEX_URL=${TORCH_CUDA_INDEX_URL}" \
    --build-arg "VLLM_CUDA_WHEEL_URL=${VLLM_CUDA_WHEEL_URL}"

build_image \
    "${SUPERGEMMA_IMAGE}" \
    "docker/vllm-supergemma.Dockerfile" \
    --build-arg "BASE_IMAGE=${VLLM_BASE_IMAGE}" \
    --build-arg "MODELOPT_PATCH_URL=${MODELOPT_PATCH_URL}" \
    --build-arg "SERVING_PATCH_URL=${SERVING_PATCH_URL}"

build_image \
    "${CODER_IMAGE}" \
    "docker/vllm-coder.Dockerfile" \
    --build-arg "BASE_IMAGE=${VLLM_BASE_IMAGE}"

log "Installing Spark systemd units..."
render_template "${PROJECT_DIR}/systemd/vllm-supergemma.service.tpl" "${SYSTEMD_DIR}/vllm-supergemma.service"
render_template "${PROJECT_DIR}/systemd/vllm-coder.service.tpl" "${SYSTEMD_DIR}/vllm-coder.service"

if [ -f "${SYSTEMD_DIR}/vllm-qwen.service" ]; then
    log "Removing legacy vllm-qwen.service..."
    sudo systemctl disable --now vllm-qwen.service >/dev/null 2>&1 || true
    sudo rm -f "${SYSTEMD_DIR}/vllm-qwen.service"
fi

log "Reloading systemd and enabling vLLM services..."
sudo systemctl daemon-reload
sudo systemctl enable vllm-supergemma.service vllm-coder.service

echo ""
log "Setup complete."
log "  SuperGemma NVFP4 path: ${SUPERGEMMA_DIR}"
log "  Nemotron coder path:  ${CODER_DIR}"
log "  State/cache root:     ${STATE_DIR}"
log "  Base image:           ${VLLM_BASE_IMAGE}"
log "  SuperGemma image:     ${SUPERGEMMA_IMAGE}"
log "  Coder image:          ${CODER_IMAGE}"
log ""
log "Next steps:"
log "  1. On MBA, run:    ./scripts/mba-deploy.sh"
log "  2. On MBA, run:    spark-resume.sh   (starts both Spark vLLM services)"
log "  3. Anytime:        spark-status.sh"
