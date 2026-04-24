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
    cmake --build build -j$(nproc)

# The GGUF is bind-mounted from the host at runtime (see spark/docker-compose.yaml),
# so the image does not bundle weights. spark-setup.sh downloads the model on the host.

EXPOSE 8080
ENTRYPOINT ["/opt/llama.cpp/build/bin/llama-server"]
