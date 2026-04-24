# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine agent setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`, IP `192.168.1.96`) — runs a single `llama.cpp CUDA` service via Docker Compose using the upstream `ghcr.io/ggml-org/llama.cpp:server-cuda` image (arm64, CUDA 12.8). SM 12.1 (GB10 Blackwell) is reached via PTX JIT at first model load:
  - Qwen3.6-27B Q4_K_M on `:8001` (~17.5 GB weights, Q8_0 KV cache, parallel=24)
- **MacBook Air** (`sloppy@sloppy-mba.local`) — runs Hermes, OpenClaw, and a local `LiteLLM` router on `127.0.0.1:4000`

GPU memory budget: Qwen3.6-27B Q4 at 17.5 GB + 24 parallel slots of Q8_0 KV cache (~3.5 GB each) ≈ ~101 GB total. No GPU memory cap flag needed — llama.cpp loads weights and uses remaining unified memory for KV cache.

The repo is cloned to both machines and scripts are run on whichever side they target. Editing configs or scripts means: commit, push, pull on the other box, then rerun `mba-deploy.sh` on the MBA so the staged runtime configs in `~/.spark-agents/` are refreshed and the live configs in `~/.hermes/` + `~/.openclaw/` are replaced.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `hf` via pipx, validates Docker availability, downloads the Qwen3.6-27B GGUF model into `/models/27b-q4`, builds the llama.cpp container image, and removes legacy vLLM containers. |
| `./scripts/mba-deploy.sh` | MBA, after config/script edits | Stages `hermes/`, `openclaw/`, and `litellm/` configs into `~/.spark-agents`, restarts LiteLLM in the active mode, copies the live configs into `~/.hermes/` + `~/.openclaw/`, restarts Hermes/OpenClaw once, and installs `spark-*.sh` into `~/bin`. |
| `spark-resume.sh` | MBA, daily | Starts the Spark llama.cpp service via `docker compose up -d` over SSH (compose file lives in the Spark repo checkout at `~/spark-agents/spark/`), waits for `/v1/models`, runs a chat health check, then switches LiteLLM into `agent-mode`. Hermes/OpenClaw stay running. |
| `spark-pause.sh` | MBA, before reclaiming the Spark GPU | Switches LiteLLM into `offload-mode` first, then stops the Spark llama.cpp service via `docker compose down` over SSH. Hermes/OpenClaw stay running. |
| `spark-status.sh` | MBA, anytime | Reports LiteLLM health/mode, Spark llama.cpp health, and Hermes/OpenClaw process state. Read-only. |

There are no tests, no build, and no linter — it's shell + YAML + JSON.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **any other GPU compute** (benchmarks, fine-tunes, ad-hoc inference). Non-agent workloads must never compete with the agent llama.cpp service for GPU memory.

The enforcement point is the MBA-side `LiteLLM` router:

- **Agent mode** (`spark-resume.sh`):
  - start Spark llama.cpp via `docker compose up -d`
  - wait for health
  - switch LiteLLM to `agent-mode`
  - `general`/`fast` route to Spark Qwen3.6-27B Q4
- **Offload mode** (`spark-pause.sh`):
  - switch LiteLLM to `offload-mode`
  - stop Spark llama.cpp via `docker compose down`
  - `general` routes to hosted OpenRouter
  - the Spark GPU is then free for any non-agent compute

Contract for future edits: pause/resume scripts should only flip LiteLLM mode and the Spark llama.cpp service. Do not make them restart Hermes or OpenClaw again unless the user explicitly asks for that behavior back.

### Model roles

One model name is exposed to the agents through LiteLLM, backed by the llama.cpp container:

- `general` — Qwen3.6-27B Q4_K_M, non-thinking (reasoning-budget 0), tool-calling lane
- `fast` — same as `general`, alternative alias for Hermes routing
- `general-think` — same endpoint, alias kept for compatibility (thinking disabled at server level)
- `general-cloud` — hosted OpenRouter fallback

Agents pick by model name. All aliases route to the same llama.cpp endpoint.

OpenClaw uses `fast` as primary, `general-cloud` as fallback.

### Config deployment flow

Repo configs live under:

- `hermes/cli-config.yaml`
- `openclaw/config.json`
- `litellm/agent-mode.yaml`
- `litellm/offload-mode.yaml`

`mba-deploy.sh` stages them into `~/.spark-agents/`, then copies the live agent configs into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy.**

### Spark llama.cpp service

The Docker Compose file at `spark/docker-compose.yaml` runs directly from the repo checkout on the Spark (`~/spark-agents/spark/`). It mounts the GGUF model from `/models/27b-q4` and runs with:
- `--parallel 24` (concurrent request slots)
- `--cache-type-k q8_0 --cache-type-v q8_0` (quantized KV cache)
- `--ctx-size 262144` (full context window)
- `--reasoning-budget 0` (no thinking blocks)
- `--no-mmap` (GB10 performance fix — mmap is 4x slower)
- `--jinja` (Jinja chat templates)
- `--log-disable` (reduced log spam)

Resume/pause scripts SSH to the Spark and run `docker compose up -d` / `docker compose down` from there. No sudo needed — the `carlid` user is in the `docker` group.

### Docker images

- **`ghcr.io/ggml-org/llama.cpp:server-cuda`** — upstream official image (org: `ggml-org`, multi-arch incl. `arm64`). CUDA 12.8.1 base. Built without an explicit `CMAKE_CUDA_ARCHITECTURES`, so SM 12.1 (GB10) is reached via PTX JIT at first load. `spark-setup.sh` just `docker pull`s this image; nothing is built locally.

### NVIDIA container runtime on the Spark

One-time setup (requires sudo): `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`. Without the `nvidia` runtime registered with the daemon, `docker info` lists only `runc` and compose's `deploy.resources.reservations.devices[driver=nvidia]` silently falls back to CPU. Symptom: llama.cpp logs `ggml_cuda_init: failed to initialize CUDA: CUDA driver is a stub library` and decode crawls at ~5 tok/s.

### Legacy images (no longer built)

- `spark-agents/vllm-base:cu132` — old vLLM CUDA base. Can be removed after confirming llama.cpp is stable.
- `spark-agents/vllm-qwen:local` — old Qwen3.6 MoE FP8 vLLM service. Kept on disk in case of rollback.
- `spark-agents/vllm-supergemma:local` — old SuperGemma4 NVFP4 vLLM. Kept on disk for potential swap-back.

To clean up: `docker image prune -a` on the Spark after confirming llama.cpp is stable.

### LiteLLM notes

- `litellm_settings.ssl_verify` must be `false`. Earlier LiteLLM versions needed `~` (YAML null) but the current version creates an SSL context from `None`, breaking plain HTTP connections. `false` correctly disables SSL for `http://` endpoints.
- The Spark `api_base` URLs use the static IP (`192.168.1.96`) rather than mDNS (`slopinator-s-1.local`) because Python's asyncio resolver does not support `.local` mDNS on macOS.
- The LiteLLM router runs in a Docker container on the MBA with `network_mode: host`. Docker Desktop's "Enable host networking" setting must be enabled for the container to reach the Spark's LAN IP.
