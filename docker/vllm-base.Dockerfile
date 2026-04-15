FROM nvidia/cuda:13.0.1-cudnn-devel-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TORCH_CUDA_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG VLLM_CUDA_WHEEL_URL=https://wheels.vllm.ai/2a69949bdadf0e8942b7a1619b229cb475beef20/vllm-0.19.0%2Bcu130-cp38-abi3-manylinux_2_35_aarch64.whl

ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1
ENV HF_HOME=/root/.cache/huggingface
ENV HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub
ENV VLLM_VENV=/opt/vllm

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
        torch==2.10.0 \
        torchaudio==2.10.0 \
        torchvision==0.25.0 && \
    pip install \
        "${VLLM_CUDA_WHEEL_URL}" \
        "transformers>=5.5.0,<5.6"
