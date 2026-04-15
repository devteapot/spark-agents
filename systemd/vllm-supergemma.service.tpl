[Unit]
Description=spark-agents vLLM SuperGemma service
Requires=docker.service
After=docker.service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
TimeoutStartSec=0
TimeoutStopSec=180
KillMode=control-group
ExecStartPre=-__DOCKER_BIN__ rm -f spark-vllm-supergemma
ExecStart=__DOCKER_BIN__ run --rm --name spark-vllm-supergemma --network host --gpus all --ipc host --shm-size 16g --ulimit memlock=-1 --ulimit stack=67108864 -e HF_HOME=/root/.cache/huggingface -e HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub -e VLLM_USE_FLASHINFER_MOE_FP4=0 -v __SUPERGEMMA_MODEL_PATH__:/models/supergemma:ro -v __SUPERGEMMA_CACHE_DIR__:/root/.cache __SUPERGEMMA_IMAGE__ vllm serve /models/supergemma --host 0.0.0.0 --port 8001 --served-model-name AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4 --quantization modelopt --dtype auto --kv-cache-dtype fp8_e4m3 --calculate-kv-scales --tensor-parallel-size 1 --max-model-len 32768 --max-num-seqs 2 --gpu-memory-utilization 0.28 --trust-remote-code --enable-chunked-prefill --enable-prefix-caching --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
ExecStop=__DOCKER_BIN__ stop --timeout 60 spark-vllm-supergemma
ExecStopPost=-__DOCKER_BIN__ rm -f spark-vllm-supergemma
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
