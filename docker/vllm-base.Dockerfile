FROM nvidia/cuda:13.2.0-cudnn-devel-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TORCH_CUDA_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG VLLM_WHEEL_URL=https://github.com/eugr/spark-vllm-docker/releases/download/prebuilt-vllm-current/vllm-0.19.1rc1.dev322%2Bg03f8d3a54.d20260415.cu132-cp312-cp312-linux_aarch64.whl
ARG FLASHINFER_CUBIN_URL=https://github.com/eugr/spark-vllm-docker/releases/download/prebuilt-flashinfer-current/flashinfer_cubin-0.6.8-py3-none-any.whl
ARG FLASHINFER_JIT_URL=https://github.com/eugr/spark-vllm-docker/releases/download/prebuilt-flashinfer-current/flashinfer_jit_cache-0.6.8-cp39-abi3-manylinux_2_28_aarch64.whl
ARG FLASHINFER_PYTHON_URL=https://github.com/eugr/spark-vllm-docker/releases/download/prebuilt-flashinfer-current/flashinfer_python-0.6.8-py3-none-any.whl

ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1
ENV HF_HOME=/root/.cache/huggingface
ENV HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub
ENV VLLM_VENV=/opt/vllm
ENV TORCH_CUDA_ARCH_LIST="12.1a"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv "${VLLM_VENV}"

ENV PATH="${VLLM_VENV}/bin:${PATH}"

RUN pip install --upgrade pip setuptools wheel packaging && \
    pip install \
        --index-url "${TORCH_CUDA_INDEX_URL}" \
        torch==2.11.0 && \
    pip install \
        "${VLLM_WHEEL_URL}" \
        "${FLASHINFER_CUBIN_URL}" \
        "${FLASHINFER_JIT_URL}" \
        "${FLASHINFER_PYTHON_URL}" && \
    pip install --upgrade --no-deps \
        "transformers>=5.5.0,<5.6" \
        "huggingface_hub>=1.10,<1.11"
