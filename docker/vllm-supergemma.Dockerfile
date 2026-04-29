ARG BASE_IMAGE=home-lab/vllm-base:cu132
FROM ${BASE_IMAGE}

ARG GEMMA4_PATCH_URL=https://huggingface.co/bg-digitalservices/Gemma-4-26B-A4B-it-NVFP4/resolve/main/gemma4_patched.py

ENV VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
ENV VLLM_MARLIN_USE_ATOMIC_ADD=1
ENV VLLM_USE_FLASHINFER_MOE_FP4=0
ENV VLLM_NVFP4_GEMM_BACKEND=marlin
ENV TORCH_MATMUL_PRECISION=high
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

RUN pip install --index-url https://download.pytorch.org/whl/cu130 torchvision && \
    VLLM_DIR="$(python3 -c 'import vllm; print(vllm.__path__[0])')" && \
    curl -fsSL "${GEMMA4_PATCH_URL}" -o "${VLLM_DIR}/model_executor/models/gemma4.py"
