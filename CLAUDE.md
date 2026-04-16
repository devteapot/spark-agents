# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine agent setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`, IP `192.168.1.96`) — runs a single `vLLM` service via Docker Compose on CUDA 13.2 + vLLM 0.19.1 + PyTorch 2.11 with native SM121 (GB10 Blackwell) support:
  - SuperGemma4 26B MoE NVFP4 on `:8001` (16 GiB weights, `--quantization modelopt`, patched gemma4.py for MoE scale keys)
- **MacBook Air** (`sloppy@sloppy-mba.local`) — runs Hermes, OpenClaw, and a local `LiteLLM` router on `127.0.0.1:4000`

GPU memory budget: SuperGemma at `0.92` of the GB10's 128 GiB unified memory (~118 GiB), with 256K context (`--max-model-len 262144`), fp8 KV cache (~800K tokens), and 8 concurrent request slots (`--max-num-seqs 8`).

The repo is cloned to both machines and scripts are run on whichever side they target. Editing configs or scripts means: commit, push, pull on the other box, then rerun `mba-deploy.sh` on the MBA so the staged runtime configs in `~/.spark-agents/` are refreshed and the live configs in `~/.hermes/` + `~/.openclaw/` are replaced.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `hf` via pipx, validates Docker availability, downloads the SuperGemma model into `/srv/models`, builds the vLLM container images, and migrates any legacy systemd units. |
| `./scripts/mba-deploy.sh` | MBA, after config/script edits | Stages `hermes/`, `openclaw/`, and `litellm/` configs into `~/.spark-agents`, restarts LiteLLM in the active mode, copies the live configs into `~/.hermes/` + `~/.openclaw/`, restarts Hermes/OpenClaw once, and installs `spark-*.sh` into `~/bin`. |
| `spark-resume.sh` | MBA, daily | Starts the Spark vLLM service via `docker compose up -d` over SSH (compose file lives in the Spark repo checkout at `~/spark-agents/spark/`), waits for `/v1/models`, runs a chat health check, then switches LiteLLM into `agent-mode`. Hermes/OpenClaw stay running. |
| `spark-pause.sh` | MBA, before reclaiming the Spark GPU | Switches LiteLLM into `offload-mode` first, then stops the Spark vLLM service via `docker compose down` over SSH. Hermes/OpenClaw stay running. |
| `spark-status.sh` | MBA, anytime | Reports LiteLLM health/mode, Spark vLLM health, and Hermes/OpenClaw process state. Read-only. |

There are no tests, no build, and no linter — it's shell + YAML + JSON.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **any other GPU compute** (benchmarks, fine-tunes, ad-hoc inference). Non-agent workloads must never compete with the agent vLLM service for GPU memory.

The enforcement point is the MBA-side `LiteLLM` router:

- **Agent mode** (`spark-resume.sh`):
  - start Spark vLLM via `docker compose up -d`
  - wait for health
  - switch LiteLLM to `agent-mode`
  - `general` routes to Spark SuperGemma NVFP4
- **Offload mode** (`spark-pause.sh`):
  - switch LiteLLM to `offload-mode`
  - stop Spark vLLM via `docker compose down`
  - `general` routes to hosted OpenRouter
  - the Spark GPU is then free for any non-agent compute

Contract for future edits: pause/resume scripts should only flip LiteLLM mode and the Spark vLLM service. Do not make them restart Hermes or OpenClaw again unless the user explicitly asks for that behavior back.

### Model roles

One stable logical model name is exposed to both agents through LiteLLM:

- `general`

There is also a hidden hosted alias for explicit fallback:

- `general-cloud`

Both Hermes and OpenClaw use `general` for all tasks. OpenClaw falls back to `general-cloud` if the primary is unavailable.

### Config deployment flow

Repo configs live under:

- `hermes/cli-config.yaml`
- `openclaw/config.json`
- `litellm/agent-mode.yaml`
- `litellm/offload-mode.yaml`

`mba-deploy.sh` stages them into `~/.spark-agents/`, then copies the live agent configs into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy.**

### Spark vLLM service

The Docker Compose file at `spark/docker-compose.yaml` runs directly from the repo checkout on the Spark (`~/spark-agents/spark/`). It mounts the model from `/srv/models/supergemma4-nvfp4` and the KV cache from `/srv/spark-agents/cache/supergemma`.

Resume/pause scripts SSH to the Spark and run `docker compose up -d` / `docker compose down` from there. No sudo needed — the `carlid` user is in the `docker` group.

### Docker images

Two images, both built by `spark-setup.sh`:

- **`spark-agents/vllm-base:cu132`** — CUDA 13.2 base with PyTorch 2.11, vLLM 0.19.1 (pre-built SM121 wheel from `eugr/spark-vllm-docker`), and FlashInfer 0.6.8. Sets `TORCH_CUDA_ARCH_LIST=12.1a` for native GB10 support.
- **`spark-agents/vllm-supergemma:local`** — inherits base, adds torchvision (for `Gemma4VideoProcessor`) and a patched `gemma4.py` from `bg-digitalservices/Gemma-4-26B-A4B-it-NVFP4` that fixes MoE NVFP4 scale-key mapping ([vLLM #38912](https://github.com/vllm-project/vllm/issues/38912)).

### LiteLLM notes

- `litellm_settings.ssl_verify` must be `false`. Earlier LiteLLM versions needed `~` (YAML null) but the current version creates an SSL context from `None`, breaking plain HTTP connections. `false` correctly disables SSL for `http://` endpoints.
- The Spark `api_base` URLs use the static IP (`192.168.1.96`) rather than mDNS (`slopinator-s-1.local`) because Python's asyncio resolver does not support `.local` mDNS on macOS.
- The LiteLLM router runs in a Docker container on the MBA with `network_mode: host`. Docker Desktop's "Enable host networking" setting must be enabled for the container to reach the Spark's LAN IP.
