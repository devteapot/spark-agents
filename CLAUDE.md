# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine agent setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`) - runs two `vLLM` services:
  - `vllm-supergemma.service` on `:8001`
  - `vllm-coder.service` on `:8002`
- **MacBook Air** (`sloppy@sloppy-mba.local`) - runs Hermes, OpenClaw, and a local `LiteLLM` router on `127.0.0.1:4000`

The repo is cloned to both machines and scripts are run on whichever side they target. Editing configs or scripts means: commit, push, pull on the other box, then rerun `mba-deploy.sh` on the MBA so the staged runtime configs in `~/.spark-agents/` are refreshed and the live configs in `~/.hermes/` + `~/.openclaw/` are replaced.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `hf` via pipx, validates Docker availability, downloads the Spark model repos into `/srv/models`, builds custom Spark-side `vLLM` container images, writes the Spark systemd units, `daemon-reload`, and enables them. |
| `./scripts/mba-deploy.sh` | MBA, after config/script edits | Stages `hermes/`, `openclaw/`, and `litellm/` configs into `~/.spark-agents`, restarts LiteLLM in the active mode, copies the live configs into `~/.hermes/` + `~/.openclaw/`, restarts Hermes/OpenClaw once, and installs `spark-*.sh` into `~/bin`. |
| `spark-resume.sh` | MBA, daily | Starts both Spark `vLLM` services over SSH using a single remote `sudo bash -se` path, waits for `/v1/models`, runs a basic chat + tool-call health check, then switches LiteLLM into `agent-mode`. Hermes/OpenClaw stay running. |
| `spark-pause.sh` | MBA, before benchmarking | Switches LiteLLM into `benchmark-mode` first, then stops both Spark `vLLM` services over SSH. Hermes/OpenClaw stay running. |
| `spark-status.sh` | MBA, anytime | Reports LiteLLM health/mode, Spark `vLLM` health, and Hermes/OpenClaw process state. Read-only. |

There are no tests, no build, and no linter - it's shell + YAML + JSON + service templates.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **direct benchmarking**. The benchmark workflow must never inherit agent inference traffic.

The enforcement point is the MBA-side `LiteLLM` router:

- **Agent mode** (`spark-resume.sh`):
  - start Spark `vLLM` services
  - wait for health
  - switch LiteLLM to `agent-mode`
  - `general` routes to Spark SuperGemma NVFP4
  - `coder` routes to Spark Nemotron Super NVFP4
- **Benchmark mode** (`spark-pause.sh`):
  - switch LiteLLM to `benchmark-mode`
  - stop Spark `vLLM` services
  - `general` routes to hosted OpenRouter
  - `coder` routes to hosted OpenRouter

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
- `litellm/benchmark-mode.yaml`

`mba-deploy.sh` stages them into `~/.spark-agents/`, then copies the live agent configs into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/cli-config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy.**

### Spark model files

Spark-local model repos live under `/srv/models`:

- `/srv/models/supergemma4-nvfp4`
- `/srv/models/nemotron-super-nvfp4`

The systemd unit templates in `systemd/` render those paths into Docker-backed `vLLM` service definitions. The images are built from the repo Dockerfiles in `docker/`. If you change the download location, update both `spark-setup.sh` and the rendered service templates.
