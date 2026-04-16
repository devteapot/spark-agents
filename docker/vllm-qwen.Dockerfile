ARG BASE_IMAGE=spark-agents/vllm-base:cu132
FROM ${BASE_IMAGE}

ENV VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
ENV TORCH_MATMUL_PRECISION=high
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

RUN pip install --index-url https://download.pytorch.org/whl/cu130 torchvision
