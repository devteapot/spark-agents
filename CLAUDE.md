# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a three-node home lab agent setup:

| Node | Host | Role |
|------|------|------|
| **DGX Spark** | Spark | vLLM serving — Qwen3.6-35B-A3B FP8 (GB10, 128 GiB) |
| **New Node** | n1 | Reserved for future dense/MoE models (RTX 3090, 24 GiB) |
| **MacBook Air** | MBA | Hermes, OpenClaw, LiteLLM router on `localhost:4000` |

GPU memory budget on Spark: Qwen3.6 FP8 at `0.92` of the GB10's 128 GiB unified memory (~118 GiB), with 256K context (`--max-model-len 262144`), fp8 KV cache, and 8 concurrent request slots (`--max-num-seqs 8`). SuperGemma4 NVFP4 model and image are also kept on disk for potential swap-back.

The repo is cloned to all machines and scripts are run on whichever side they target. Editing configs or scripts means: commit, push, pull on the other box, then rerun `mba-deploy.sh` on the MBA so the staged runtime configs in `~/.home-lab/` are refreshed and the live configs in `~/.hermes/` + `~/.openclaw/` are replaced.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/lab-setup.sh` | Spark, once | Installs `hf` via pipx, validates Docker availability, downloads models into `/srv/models`, builds the vLLM container images, and migrates any legacy systemd units. |
| `./scripts/mba-deploy.sh` | MBA, after config/script edits | Stages `hermes/`, `openclaw/`, and `litellm/` configs into `~/.home-lab`, restarts LiteLLM in the active mode, copies the live configs into `~/.hermes/` + `~/.openclaw/`, restarts Hermes/OpenClaw once, and installs `lab-*.sh` into `~/bin`. |
| `lab-resume.sh` | MBA, daily | Starts the Spark vLLM service via `docker compose up -d` over SSH (compose file lives in the Spark repo checkout at `~/home-lab/spark/`), waits for `/v1/models`, runs a chat health check, then switches LiteLLM into `agent-mode`. Hermes/OpenClaw stay running. |
| `lab-pause.sh` | MBA, before reclaiming the Spark GPU | Switches LiteLLM into `offload-mode` first, then stops the Spark vLLM service via `docker compose down` over SSH. Hermes/OpenClaw stay running. |
| `lab-status.sh` | MBA, anytime | Reports LiteLLM health/mode, Spark vLLM health, and Hermes/OpenClaw process state. Read-only. |

There are no tests, no build, and no linter — it's shell + YAML + JSON.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **any other GPU compute** (benchmarks, fine-tunes, ad-hoc inference). Non-agent workloads must never compete with the agent vLLM service for GPU memory.

The enforcement point is the MBA-side `LiteLLM` router:

- **Agent mode** (`lab-resume.sh`):
  - start Spark vLLM via `docker compose up -d`
  - wait for health
  - switch LiteLLM to `agent-mode`
  - `general` routes to Spark Qwen3.6 FP8
- **Offload mode** (`lab-pause.sh`):
  - switch LiteLLM to `offload-mode`
  - stop Spark vLLM via `docker compose down`
  - `general` routes to hosted OpenRouter
  - the Spark GPU is then free for any non-agent compute

Contract for future edits: pause/resume scripts should only flip LiteLLM mode and the Spark vLLM service. Do not make them restart Hermes or OpenClaw again unless the user explicitly asks for that behavior back.

### Model roles

Two logical model names are exposed to the agents through LiteLLM, both backed by the same Qwen3.6 vLLM container:

- `general` — `chat_template_kwargs.enable_thinking: false`, fast tool-calling / instruct lane
- `general-think` — `chat_template_kwargs.enable_thinking: true`, reasoning lane (emits `<think>…</think>`, parsed into `reasoning_content` by vLLM's `qwen3` reasoning parser)

There is also a hidden hosted alias for explicit fallback:

- `general-cloud`

Both `general` and `general-think` share the same `--max-num-seqs 8` slot pool and KV cache on the Spark; there's no extra GPU memory cost. Agents pick by model name. Neither Hermes nor OpenClaw supports `chat_template_kwargs` passthrough to local endpoints, so the thinking policy lives in LiteLLM, not in agent requests.

OpenClaw falls back to `general-cloud` if the primary is unavailable.

### Config deployment flow

Repo configs live under:

- `hermes/cli-config.yaml`
- `openclaw/config.json`
- `litellm/agent-mode.yaml`
- `litellm/offload-mode.yaml`

`mba-deploy.sh` stages them into `~/.home-lab/`, then copies the live agent configs into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy.**

### Spark vLLM service

The Docker Compose file at `spark/docker-compose.yaml` runs directly from the repo checkout on the Spark (`~/home-lab/spark/`). It mounts the model from `/srv/models/qwen3.6-35b-a3b-fp8` and the KV cache from `/srv/home-lab/cache/qwen`.

Resume/pause scripts SSH to the Spark and run `docker compose up -d` / `docker compose down` from there. No sudo needed — the `carlid` user is in the `docker` group.

### Docker images

Three images, all built by `lab-setup.sh`:

- **`home-lab/vllm-base:cu132`** — CUDA 13.2 base with PyTorch 2.11, vLLM dev337 (pre-built SM121 wheel from `eugr/spark-vllm-docker`), and FlashInfer 0.6.8. Sets `TORCH_CUDA_ARCH_LIST=12.1a` for native GB10 support.
- **`home-lab/vllm-qwen:local`** — inherits base, adds torchvision for Qwen3.6 multimodal (vision+text). No patches needed — FP8 and `qwen3_5_moe` are natively supported.
- **`home-lab/vllm-supergemma:local`** — inherits base, adds torchvision and a patched `gemma4.py` for MoE NVFP4 scale-key mapping ([vLLM #38912](https://github.com/vllm-project/vllm/issues/38912)). Not actively loaded; kept for swap-back.

### LiteLLM notes

- `litellm_settings.ssl_verify` must be `false`. Earlier LiteLLM versions needed `~` (YAML null) but the current version creates an SSL context from `None`, breaking plain HTTP connections. `false` correctly disables SSL for `http://` endpoints.
- The Spark `api_base` URL (`http://slopinator-s-1.local:8001/v1`) uses the `.local` hostname, but the LitellM container uses the static IP (`192.168.1.96`) because Python's asyncio resolver on macOS does not support `.local` mDNS reliably.
- The LiteLLM router runs in a Docker container on the MBA with `network_mode: host`. Docker Desktop's "Enable host networking" setting must be enabled for the container to reach the Spark's LAN IP.
