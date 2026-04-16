# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine agent setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`, IP `192.168.1.96`) - runs two `vLLM` services on CUDA 13.2 + vLLM 0.19.1 + PyTorch 2.11 with native SM121 (GB10 Blackwell) support:
  - `vllm-supergemma.service` on `:8001` — SuperGemma4 26B MoE NVFP4 (16 GiB, `--quantization modelopt`, patched gemma4.py for MoE scale keys)
  - `vllm-coder.service` on `:8002` — Qwen3-Coder-Next 80B/3B-A MoE NVFP4 (44 GiB, `--quantization compressed-tensors`)
- **MacBook Air** (`sloppy@sloppy-mba.local`) - runs Hermes, OpenClaw, and a local `LiteLLM` router on `127.0.0.1:4000`

GPU memory budget: coder `0.55` + supergemma `0.30` = `0.85` of the GB10's 128 GiB unified memory, leaving 15% headroom.

The repo is cloned to both machines and scripts are run on whichever side they target. Editing configs or scripts means: commit, push, pull on the other box, then rerun `mba-deploy.sh` on the MBA so the staged runtime configs in `~/.spark-agents/` are refreshed and the live configs in `~/.hermes/` + `~/.openclaw/` are replaced.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `hf` via pipx, validates Docker availability, downloads the Spark model repos into `/srv/models`, builds custom Spark-side `vLLM` container images, writes the Spark systemd units, `daemon-reload`, and enables them. |
| `./scripts/mba-deploy.sh` | MBA, after config/script edits | Stages `hermes/`, `openclaw/`, and `litellm/` configs into `~/.spark-agents`, restarts LiteLLM in the active mode, copies the live configs into `~/.hermes/` + `~/.openclaw/`, restarts Hermes/OpenClaw once, and installs `spark-*.sh` into `~/bin`. |
| `spark-resume.sh` | MBA, daily | Starts both Spark `vLLM` services over SSH using a single remote `sudo bash -se` path, waits for `/v1/models`, runs a basic chat + tool-call health check, then switches LiteLLM into `agent-mode`. Hermes/OpenClaw stay running. |
| `spark-pause.sh` | MBA, before reclaiming the Spark GPU | Switches LiteLLM into `offload-mode` first, then stops both Spark `vLLM` services over SSH. Hermes/OpenClaw stay running. |
| `spark-status.sh` | MBA, anytime | Reports LiteLLM health/mode, Spark `vLLM` health, and Hermes/OpenClaw process state. Read-only. |

There are no tests, no build, and no linter - it's shell + YAML + JSON + service templates.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **any other GPU compute** (benchmarks, fine-tunes, ad-hoc inference). Non-agent workloads must never compete with the agent vLLM services for GPU memory.

The enforcement point is the MBA-side `LiteLLM` router:

- **Agent mode** (`spark-resume.sh`):
  - start Spark `vLLM` services
  - wait for health
  - switch LiteLLM to `agent-mode`
  - `general` routes to Spark SuperGemma NVFP4
  - `coder` routes to Spark Qwen3-Coder-Next NVFP4
- **Offload mode** (`spark-pause.sh`):
  - switch LiteLLM to `offload-mode`
  - stop Spark `vLLM` services
  - `general` routes to hosted OpenRouter
  - `coder` routes to hosted OpenRouter
  - the Spark GPU is then free for any non-agent compute (benchmarks, fine-tunes, ad-hoc inference)

Contract for future edits: pause/resume scripts should only flip LiteLLM mode and Spark-local services. Do not make them restart Hermes or OpenClaw again unless the user explicitly asks for that behavior back.

### Model roles

Two stable logical model names are exposed to both agents through LiteLLM:

- `general`
- `coder`

There are also hidden hosted aliases for explicit fallbacks:

- `general-cloud`
- `coder-cloud`

Hermes defaults to `coder` and down-routes quick/simple turns to `general` via `smart_model_routing`. OpenClaw defaults to `general` and falls back to `coder`, then the hidden cloud aliases.

### Config deployment flow

Repo configs live under:

- `hermes/cli-config.yaml`
- `openclaw/config.json`
- `litellm/agent-mode.yaml`
- `litellm/offload-mode.yaml`

`mba-deploy.sh` stages them into `~/.spark-agents/`, then copies the live agent configs into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy.**

### Spark model files

Spark-local model repos live under `/srv/models`:

- `/srv/models/supergemma4-nvfp4`
- `/srv/models/qwen3-coder-next-nvfp4`

The systemd unit templates in `systemd/` render those paths into Docker-backed `vLLM` service definitions. The images are built from the repo Dockerfiles in `docker/`. If you change the download location, update both `spark-setup.sh` and the rendered service templates.

### Docker images

Three images, all built by `spark-setup.sh`:

- **`spark-agents/vllm-base:cu132`** — CUDA 13.2 base with PyTorch 2.11, vLLM 0.19.1 (pre-built SM121 wheel from `eugr/spark-vllm-docker`), and FlashInfer 0.6.8. Sets `TORCH_CUDA_ARCH_LIST=12.1a` for native GB10 support.
- **`spark-agents/vllm-supergemma:local`** — inherits base, adds torchvision (for `Gemma4VideoProcessor`) and a patched `gemma4.py` from `bg-digitalservices/Gemma-4-26B-A4B-it-NVFP4` that fixes MoE NVFP4 scale-key mapping ([vLLM #38912](https://github.com/vllm-project/vllm/issues/38912)).
- **`spark-agents/vllm-coder:local`** — inherits base with no modifications.

### LiteLLM notes

- `litellm_settings.ssl_verify` must be `~` (YAML null / Python None), **not** `false`. In LiteLLM's aiohttp transport, `ssl=False` means "use SSL but skip cert check" which breaks plain HTTP connections. `None` means "default behavior" (no SSL for `http://`).
- The Spark `api_base` URLs use the static IP (`192.168.1.96`) rather than mDNS (`slopinator-s-1.local`) because Python's asyncio resolver does not support `.local` mDNS on macOS.
