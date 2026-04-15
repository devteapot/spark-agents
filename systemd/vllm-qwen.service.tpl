[Unit]
Description=spark-agents vLLM Qwen coder service
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
ExecStart=__VLLM_BIN__ serve __QWEN_MODEL_PATH__ --host 0.0.0.0 --port 8002 --served-model-name Qwen/Qwen3-Coder-Next-FP8 --max-model-len 32768 --enable-auto-tool-choice --tool-call-parser qwen3_coder
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
