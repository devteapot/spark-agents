[Unit]
Description=spark-agents vLLM coder service
Requires=docker.service
After=docker.service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
TimeoutStartSec=0
TimeoutStopSec=180
KillMode=control-group
ExecStartPre=-__DOCKER_BIN__ rm -f spark-vllm-coder
ExecStart=__DOCKER_BIN__ run --rm --name spark-vllm-coder --network host --gpus all --ipc host --shm-size 16g --ulimit memlock=-1 --ulimit stack=67108864 -e HF_HOME=/root/.cache/huggingface -e HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub -e VLLM_NVFP4_GEMM_BACKEND=marlin -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 -e VLLM_FLASHINFER_ALLREDUCE_BACKEND=trtllm -e VLLM_USE_FLASHINFER_MOE_FP4=0 -v __CODER_MODEL_PATH__:/models/coder:ro -v __CODER_CACHE_DIR__:/root/.cache __CODER_IMAGE__ vllm serve /models/coder --host 0.0.0.0 --port 8002 --served-model-name nvidia/nemotron-3-super --async-scheduling --dtype auto --kv-cache-dtype fp8 --tensor-parallel-size 1 --pipeline-parallel-size 1 --data-parallel-size 1 --trust-remote-code --gpu-memory-utilization 0.70 --enable-chunked-prefill --max-num-seqs 4 --max-model-len 32768 --moe-backend marlin --mamba-ssm-cache-dtype float32 --quantization fp4 --reasoning-parser-plugin /models/coder/super_v3_reasoning_parser.py --reasoning-parser super_v3 --enable-auto-tool-choice --tool-call-parser qwen3_coder
ExecStop=__DOCKER_BIN__ stop --timeout 60 spark-vllm-coder
ExecStopPost=-__DOCKER_BIN__ rm -f spark-vllm-coder
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
