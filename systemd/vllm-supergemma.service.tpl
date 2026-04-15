[Unit]
Description=spark-agents vLLM SuperGemma service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=__SPARK_USER__
Group=__SPARK_GROUP__
WorkingDirectory=__PROJECT_DIR__
Environment=HF_HOME=__HF_HOME__
Environment=HUGGINGFACE_HUB_CACHE=__HF_HOME__/hub
Environment=PYTHONUNBUFFERED=1
Environment=VLLM_TEST_FORCE_FP8_MARLIN=1
Environment=VLLM_MARLIN_USE_ATOMIC_ADD=1
Environment=VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
Environment=VLLM_USE_FLASHINFER_MOE_FP4=1
Environment=TORCH_MATMUL_PRECISION=high
Environment=PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
ExecStart=__VLLM_BIN__ serve __SUPERGEMMA_MODEL_PATH__ --host 0.0.0.0 --port 8001 --served-model-name AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4 --quantization modelopt --dtype auto --kv-cache-dtype fp8_e4m3 --calculate-kv-scales --tensor-parallel-size 1 --max-model-len 65536 --max-num-seqs 4 --gpu-memory-utilization 0.90 --trust-remote-code --enable-chunked-prefill --enable-prefix-caching --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
