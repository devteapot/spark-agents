ARG BASE_IMAGE=spark-agents/vllm-base:cu132
FROM ${BASE_IMAGE}

ARG MODELOPT_PATCH_URL=https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/modelopt_patched.py
ARG SERVING_PATCH_URL=https://raw.githubusercontent.com/AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4/main/serving_chat_patched.py

ENV VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
ENV VLLM_MARLIN_USE_ATOMIC_ADD=1
ENV VLLM_TEST_FORCE_FP8_MARLIN=1
ENV VLLM_USE_FLASHINFER_MOE_FP4=0
ENV TORCH_MATMUL_PRECISION=high
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

RUN VLLM_DIR="$(python3 -c 'import vllm; print(vllm.__path__[0])')" && \
    curl -fsSL "${MODELOPT_PATCH_URL}" -o "${VLLM_DIR}/model_executor/layers/quantization/modelopt.py" && \
    curl -fsSL "${SERVING_PATCH_URL}" -o "${VLLM_DIR}/entrypoints/openai/chat_completion/serving.py"
