# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine local-LLM setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`) — runs Ollama, hosts the models.
- **MacBook Air** (`sloppy@sloppy-mba.local`) — runs two agents (Hermes, OpenClaw) that hit the Spark's Ollama over the LAN.

The repo is cloned to both machines and scripts are run on whichever side they target. Editing a config means: commit, push, pull on the other box, then re-run `mba-deploy.sh` if MBA configs changed (they get copied into `~/.hermes/` and `~/.openclaw/`).

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `huggingface-cli` via pipx (shared, `/opt/pipx` → `/usr/local/bin`), creates `/srv/models`, downloads both GGUFs, writes the systemd override + baseline `/etc/ollama.env`, `daemon-reload`, restart, `ollama create` both tags. Prompts for sudo password once. |
| `./scripts/mba-deploy.sh` | MBA, after each config change | Stops Hermes, copies `hermes/cli-config.yaml` → `~/.hermes/`, `openclaw/config.json` → `~/.openclaw/`, installs `spark-*.sh` into `~/bin`, pings Spark Ollama. |
| `spark-resume.sh` | MBA, daily | `ssh -tt` to Spark → sudo-writes agent `/etc/ollama.env` (`NUM_PARALLEL=2`, `MAX_LOADED_MODELS=2`, `KV_CACHE_TYPE=q8_0`, `FLASH_ATTENTION=1`) → `systemctl restart ollama` → preloads both models with `keep_alive: -1` → starts `hermes` and `openclaw` locally. Prompts for Spark sudo password once. |
| `spark-pause.sh` | MBA, before benchmarking | Stops local agents, unloads both models (`keep_alive: 0`), `ssh -tt` to Spark → sudo-clears `/etc/ollama.env` → `systemctl restart ollama`. |
| `spark-status.sh` | MBA, anytime | Hits `/api/version`, `/api/ps`, `/api/tags` on Spark; checks for `hermes` and `openclaw` processes locally. Read-only. |

There are no tests, no build, no linter — it's shell + YAML + JSON + Modelfiles.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **direct benchmarking**. These need different Ollama env vars, and the benchmark workflow must never silently inherit agent tuning.

Ollama on the Spark runs as a systemd service under its own `ollama` system user. The env is split across two files, installed once by `spark-setup.sh`:

1. **`/etc/systemd/system/ollama.service.d/override.conf`** — static baseline. Pins `OLLAMA_HOST=0.0.0.0:11434` and declares `EnvironmentFile=-/etc/ollama.env`. Never rewritten after setup. The leading `-` on `EnvironmentFile` makes the env file optional so empty/missing is fine.
2. **`/etc/ollama.env`** — dynamic tunables. Rewritten each pause/resume cycle. Never contains `OLLAMA_HOST` — the override owns that.

Pause/resume cycle:

- **Agent mode** (`spark-resume.sh`): SSHes with `ssh -tt` so sudo can prompt, writes `/etc/ollama.env` with `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`, then `systemctl restart ollama`. No `daemon-reload` — the override.conf is untouched.
- **Benchmark mode** (`spark-pause.sh`): SSHes with `ssh -tt`, rewrites `/etc/ollama.env` to an empty (comment-only) file, then `systemctl restart ollama`. Stock Ollama defaults + pinned `OLLAMA_HOST`.

Contract for future edits: never put agent tunings in `override.conf` and never put `OLLAMA_HOST` in `/etc/ollama.env`. Keep the two files single-purpose.

### Model roles

Two models, two roles, referenced from three places (`hermes/cli-config.yaml`, `openclaw/config.json`, and the Modelfiles). Keep model IDs in sync across all of them.

- `supergemma4:26b-q8` — general / primary. Modelfile sets `num_ctx 8192`, `temperature 0.6`. ~28 GB.
- `qwen3-coder-next:q6k` — coding / fallback. Modelfile sets `num_ctx 32768`, `temperature 0.3`. ~65 GB.

Hermes has `smart_model_routing` that sends short/simple turns to SuperGemma4 and longer/code-heavy turns to the Qwen coder. OpenClaw uses SuperGemma4 as primary with the Qwen coder as a named fallback.

### API endpoint quirk

Hermes connects via the **OpenAI-compatible** endpoint (`/v1`, `provider: custom`, `api_key: "ollama-local"`).
OpenClaw connects via the **native Ollama** endpoint (no `/v1`, `"api": "ollama"`) — the comment in `openclaw/config.json` says this is for reliable tool calling. Don't "unify" these without understanding why they diverge.

### Config deployment flow

Configs live in the repo (`hermes/cli-config.yaml`, `openclaw/config.json`) but the running agents read them from `~/.hermes/` and `~/.openclaw/`. `mba-deploy.sh` is the one-way copy step — **edits to `~/.hermes/cli-config.yaml` directly will be overwritten on the next deploy**. Edit the repo copy, commit, re-deploy.

### Model files

Modelfiles in `ollama/` reference absolute paths under `/srv/models/...` on the Spark. This path is deliberate: `/home/carlid` is mode 750 and the `ollama` system user cannot traverse it, so `ollama create` can't read GGUFs from there. `/srv/models` is world-readable and outside `/home` entirely. If you change where GGUFs are downloaded, update both the Modelfile `FROM` line and `MODEL_DIR` in `spark-setup.sh`.
