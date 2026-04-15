#!/usr/bin/env bash
# spark-setup.sh - Initial Spark setup for local vLLM serving
#
# Run this on the DGX Spark once. It will:
#   1. Install hf (huggingface-hub CLI) via pipx if needed
#   2. Create /srv/models and download the two HF model repos
#   3. Create a dedicated vLLM virtualenv under /opt
#   4. Apply the required NVFP4 patches for the SuperGemma vLLM path
#   5. Install the Spark-side systemd units for SuperGemma and Qwen
#   6. Enable the units so spark-resume.sh / spark-pause.sh can manage them
#
# Usage:
#   ssh carlid@slopinator-s-1.local
#   cd ~/spark-agents && ./scripts/spark-setup.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="/srv/models"
SUPERGEMMA_DIR="${MODEL_DIR}/supergemma4-nvfp4"
SUPERGEMMA_PATCH_DIR="${MODEL_DIR}/supergemma4-nvfp4-patches"
QWEN_DIR="${MODEL_DIR}/qwen3-coder-next-fp8"
VLLM_VENV="/opt/spark-agents-vllm"
VLLM_BIN="${VLLM_VENV}/bin/vllm"
VLLM_PYTHON="${VLLM_VENV}/bin/python"
SYSTEMD_DIR="/etc/systemd/system"
SPARK_USER="$(id -un)"
SPARK_GROUP="$(id -gn)"
HF_HOME="${HOME}/.cache/huggingface"
TORCH_CUDA_INDEX_URL="https://download.pytorch.org/whl/cu130"
VLLM_CUDA_WHEEL_URL="https://wheels.vllm.ai/2a69949bdadf0e8942b7a1619b229cb475beef20/vllm-0.19.0%2Bcu130-cp38-abi3-manylinux_2_35_aarch64.whl"
SUPERGEMMA_MODEL_REPO="AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4"
QWEN_MODEL_REPO="Qwen/Qwen3-Coder-Next-FP8"
MODELOPT_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/modelopt_patched.py"
SERVING_PATCH_URL="https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/serving_chat_patched.py"

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
    SPARK_USER_RENDER="${SPARK_USER}" \
    SPARK_GROUP_RENDER="${SPARK_GROUP}" \
    PROJECT_DIR_RENDER="${PROJECT_DIR}" \
    HF_HOME_RENDER="${HF_HOME}" \
    VLLM_BIN_RENDER="${VLLM_BIN}" \
    SUPERGEMMA_DIR_RENDER="${SUPERGEMMA_DIR}" \
    QWEN_DIR_RENDER="${QWEN_DIR}" \
    python3 - <<'PY' > "${tmp_file}"
import os
from pathlib import Path

text = Path(os.environ["TEMPLATE_PATH"]).read_text()
replacements = {
    "__SPARK_USER__": os.environ["SPARK_USER_RENDER"],
    "__SPARK_GROUP__": os.environ["SPARK_GROUP_RENDER"],
    "__PROJECT_DIR__": os.environ["PROJECT_DIR_RENDER"],
    "__HF_HOME__": os.environ["HF_HOME_RENDER"],
    "__VLLM_BIN__": os.environ["VLLM_BIN_RENDER"],
    "__SUPERGEMMA_MODEL_PATH__": os.environ["SUPERGEMMA_DIR_RENDER"],
    "__QWEN_MODEL_PATH__": os.environ["QWEN_DIR_RENDER"],
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
print(text, end="")
PY

    sudo install -m 0644 "${tmp_file}" "${destination}"
    rm -f "${tmp_file}"
}

log "This script needs sudo for /srv/models, /opt, and /etc/systemd writes."
sudo -v

if ! command -v python3 > /dev/null 2>&1; then
    err "python3 is required on the Spark."
    exit 1
fi

log "Ensuring system prerequisites are installed..."
sudo apt-get update -qq
sudo apt-get install -y curl python3-venv pipx

if command -v hf > /dev/null 2>&1; then
    log "hf already installed at $(command -v hf)"
else
    log "Installing hf via pipx..."
    sudo env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin \
        pipx install huggingface-hub
    log "hf installed at $(command -v hf)"
fi

mkdir -p "${HF_HOME}"

if [ ! -d "${MODEL_DIR}" ]; then
    log "Creating ${MODEL_DIR}..."
    sudo mkdir -p "${MODEL_DIR}"
    sudo chown "${SPARK_USER}:${SPARK_GROUP}" "${MODEL_DIR}"
    sudo chmod 755 "${MODEL_DIR}"
else
    log "${MODEL_DIR} already exists."
fi

mkdir -p "${SUPERGEMMA_DIR}" "${SUPERGEMMA_PATCH_DIR}" "${QWEN_DIR}"

log "Downloading ${SUPERGEMMA_MODEL_REPO} into ${SUPERGEMMA_DIR}..."
hf download \
    "${SUPERGEMMA_MODEL_REPO}" \
    --local-dir "${SUPERGEMMA_DIR}"

log "Downloading ${QWEN_MODEL_REPO} into ${QWEN_DIR}..."
hf download \
    "${QWEN_MODEL_REPO}" \
    --local-dir "${QWEN_DIR}"

if [ ! -d "${VLLM_VENV}" ]; then
    log "Creating vLLM virtualenv at ${VLLM_VENV}..."
    sudo python3 -m venv "${VLLM_VENV}"
else
    log "${VLLM_VENV} already exists."
fi

log "Installing vLLM into ${VLLM_VENV}..."
sudo "${VLLM_VENV}/bin/pip" install --upgrade pip setuptools wheel
sudo "${VLLM_VENV}/bin/pip" uninstall -y vllm torch torchaudio torchvision || true
sudo "${VLLM_VENV}/bin/pip" install \
    --index-url "${TORCH_CUDA_INDEX_URL}" \
    "torch==2.10.0" \
    "torchaudio==2.10.0" \
    "torchvision==0.25.0"
sudo "${VLLM_VENV}/bin/pip" install \
    "${VLLM_CUDA_WHEEL_URL}" \
    "transformers>=4.56.0,<5"

if [ ! -x "${VLLM_BIN}" ]; then
    err "Expected vLLM binary not found at ${VLLM_BIN}"
    exit 1
fi

log "Downloading SuperGemma NVFP4 vLLM patches..."
curl -fsSL "${MODELOPT_PATCH_URL}" -o "${SUPERGEMMA_PATCH_DIR}/modelopt_patched.py"
curl -fsSL "${SERVING_PATCH_URL}" -o "${SUPERGEMMA_PATCH_DIR}/serving_chat_patched.py"

VLLM_DIR="$("${VLLM_PYTHON}" -c "import vllm; print(vllm.__path__[0])")"
MODELOPT_TARGET="${VLLM_DIR}/model_executor/layers/quantization/modelopt.py"
SERVING_TARGET="${VLLM_DIR}/entrypoints/openai/chat_completion/serving.py"

log "Applying SuperGemma NVFP4 patches into ${VLLM_DIR}..."
sudo install -m 0644 "${SUPERGEMMA_PATCH_DIR}/modelopt_patched.py" "${MODELOPT_TARGET}"
sudo install -m 0644 "${SUPERGEMMA_PATCH_DIR}/serving_chat_patched.py" "${SERVING_TARGET}"

log "Installing Spark systemd units..."
render_template "${PROJECT_DIR}/systemd/vllm-supergemma.service.tpl" "${SYSTEMD_DIR}/vllm-supergemma.service"
render_template "${PROJECT_DIR}/systemd/vllm-qwen.service.tpl" "${SYSTEMD_DIR}/vllm-qwen.service"

log "Reloading systemd and enabling vLLM services..."
sudo systemctl daemon-reload
sudo systemctl enable vllm-supergemma.service vllm-qwen.service

echo ""
log "Setup complete."
log "  SuperGemma NVFP4 path: ${SUPERGEMMA_DIR}"
log "  SuperGemma patches:    ${SUPERGEMMA_PATCH_DIR}"
log "  Qwen FP8 path:        ${QWEN_DIR}"
log "  vLLM virtualenv:      ${VLLM_VENV}"
log ""
log "Next steps:"
log "  1. On MBA, run:    ./scripts/mba-deploy.sh"
log "  2. On MBA, run:    spark-resume.sh   (starts both Spark vLLM services)"
log "  3. Anytime:        spark-status.sh"
