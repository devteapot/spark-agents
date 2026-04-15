[Unit]
Description=spark-agents vLLM Qwen coder service
Requires=docker.service
After=docker.service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
TimeoutStartSec=0
TimeoutStopSec=180
KillMode=none
ExecStartPre=-__DOCKER_BIN__ rm -f spark-vllm-qwen
ExecStart=__DOCKER_BIN__ run --rm --name spark-vllm-qwen --network host --gpus all --ipc host --shm-size 16g --ulimit memlock=-1 --ulimit stack=67108864 -e HF_HOME=/root/.cache/huggingface -e HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub -v __QWEN_MODEL_PATH__:/models/qwen:ro -v __QWEN_CACHE_DIR__:/root/.cache __QWEN_IMAGE__ vllm serve /models/qwen --host 0.0.0.0 --port 8002 --served-model-name Qwen/Qwen3-Coder-Next-FP8 --max-model-len 32768 --gpu-memory-utilization 0.72 --max-num-seqs 4 --enable-auto-tool-choice --tool-call-parser qwen3_coder
ExecStop=__DOCKER_BIN__ stop --time 60 spark-vllm-qwen
ExecStopPost=-__DOCKER_BIN__ rm -f spark-vllm-qwen
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
