FROM nvidia/cuda:13.2.0-cudnn-devel-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive

ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git python3 python3-dev python3-pip curl \
    && rm -rf /var/lib/apt/lists/*

# Build llama.cpp with CUDA for GB10 (SM 12.1)
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /opt/llama.cpp && \
    cd /opt/llama.cpp && \
    cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --release -j$(nproc)

# Download Qwen3.6-27B GGUF models (done at build time)
RUN pip install huggingface_hub && \
    mkdir -p /models/27b-q4 && \
    huggingface-cli download bartowski/Qwen_Qwen3.6-27B-GGUF \
        "Qwen3.6-27B-Q4_K_M.gguf" \
        --local-dir /models/27b-q4 2>/dev/null || true

EXPOSE 8080
ENTRYPOINT ["/opt/llama.cpp/build/bin/llama-server"]
