# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Repository purpose

This is **not** an application. It is a configuration + deployment repo for a two-machine agent setup:

- **DGX Spark** (`carlid@slopinator-s-1.local`) — runs Ollama, hosts the models.
- **MacBook Air** (`sloppy@sloppy-mba.local`) — runs two agents (Hermes, OpenClaw) that switch between:
  - a **`local`** profile that targets the Spark over the LAN
  - a **`benchmark-cloud`** profile that targets hosted OpenRouter models while the Spark is being benchmarked

The repo is cloned to both machines and scripts are run on whichever side they target. Editing a profile or script means: commit, push, pull on the other box, then re-run `mba-deploy.sh` on the MBA so the staged runtime profiles in `~/.spark-agents/` are refreshed and the active profile is copied into `~/.hermes/` and `~/.openclaw/`.

## Common commands

All scripts live in `scripts/` and are idempotent.

| Command | Where to run | What it does |
|---|---|---|
| `./scripts/spark-setup.sh` | Spark, once | Installs `hf` (huggingface-hub CLI) via pipx (shared, `/opt/pipx` → `/usr/local/bin`), creates `/srv/models`, downloads both GGUFs, writes the systemd override + baseline `/etc/ollama.env`, `daemon-reload`, restart, `ollama create` both tags. Prompts for sudo password once. |
| `./scripts/mba-deploy.sh [--profile ...]` | MBA, after each profile/script change | Stops Hermes/OpenClaw, stages `profiles/*` into `~/.spark-agents/profiles/`, copies the selected profile into `~/.hermes/` + `~/.openclaw/`, enables OpenClaw's LAN Control UI in the live CLI config, installs `spark-*.sh` into `~/bin`, and verifies the selected profile's prerequisites. |
| `spark-resume.sh` | MBA, daily | Copies the staged `local` profile into `~/.hermes/` + `~/.openclaw/`, `ssh -tt` to Spark → sudo-writes agent `/etc/ollama.env` (`NUM_PARALLEL=2`, `MAX_LOADED_MODELS=2`, `KV_CACHE_TYPE=q8_0`, `FLASH_ATTENTION=1`) → `systemctl restart ollama` → preloads both models with `keep_alive: -1` → starts `hermes` and `openclaw` locally. Prompts for Spark sudo password once. |
| `spark-pause.sh` | MBA, before benchmarking | Validates the staged `benchmark-cloud` profile + OpenRouter keys, stops local agents, unloads both Spark models (`keep_alive: 0`), `ssh -tt` to Spark → sudo-clears `/etc/ollama.env` → `systemctl restart ollama`, then starts the agents again on the hosted profile. |
| `spark-status.sh` | MBA, anytime | Shows the active staged profile, hits `/api/version`, `/api/ps`, `/api/tags` on Spark, checks for `hermes` and `openclaw` processes locally, and prints the local/LAN web UI URLs when available. Read-only. |
| `spark-hermes-dashboard.sh` | MBA, when needed | Starts `hermes dashboard --host 0.0.0.0 --port 9119 --no-open` so the Hermes UI is reachable from other devices on the LAN. Use only on trusted networks. |

There are no tests, no build, no linter — it's shell + YAML + JSON + Modelfiles.

## Architecture

### The pause/resume pattern (the critical invariant)

The Spark is dual-use: **agent serving** and **direct benchmarking**. These need different Ollama env vars, and the benchmark workflow must never silently inherit agent tuning **or agent inference traffic**.

Ollama on the Spark runs as a systemd service under its own `ollama` system user. The env is split across two files, installed once by `spark-setup.sh`:

1. **`/etc/systemd/system/ollama.service.d/override.conf`** — static baseline. Pins `OLLAMA_HOST=0.0.0.0:11434` and declares `EnvironmentFile=-/etc/ollama.env`. Never rewritten after setup. The leading `-` on `EnvironmentFile` makes the env file optional so empty/missing is fine.
2. **`/etc/ollama.env`** — dynamic tunables. Rewritten each pause/resume cycle. Never contains `OLLAMA_HOST` — the override owns that.

Pause/resume cycle:

- **Agent mode** (`spark-resume.sh`): Copies the staged MBA `local` profile into `~/.hermes/` and `~/.openclaw/`, then SSHes with `ssh -tt` so sudo can prompt, writes `/etc/ollama.env` with `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`, then `systemctl restart ollama`. No `daemon-reload` — the override.conf is untouched.
- **Benchmark mode** (`spark-pause.sh`): Validates the staged MBA `benchmark-cloud` profile, stops the agents, SSHes with `ssh -tt`, rewrites `/etc/ollama.env` to an empty (comment-only) file, then `systemctl restart ollama`. Stock Ollama defaults + pinned `OLLAMA_HOST`. After the Spark is clean, Hermes and OpenClaw are restarted on hosted OpenRouter-backed configs.

Contract for future edits: never put agent tunings in `override.conf` and never put `OLLAMA_HOST` in `/etc/ollama.env`. Keep the two files single-purpose.

### Model roles

Two Spark models, two local roles:

- `supergemma4:26b-q8` — general / primary. Modelfile sets `num_ctx 8192`, `temperature 0.6`. ~28 GB.
- `qwen3-coder-next:q6k` — coding / fallback. Modelfile sets `num_ctx 32768`, `temperature 0.3`. ~65 GB.

In the MBA `local` profile:

- Hermes uses Qwen as the primary strong model and down-routes short/simple turns to SuperGemma via `smart_model_routing`.
- OpenClaw uses SuperGemma as primary with Qwen as the first fallback.

In the MBA `benchmark-cloud` profile:

- Both agents use hosted OpenRouter-backed models so the Spark stays free for direct benchmarking.

### API endpoint quirk

For the Spark-backed `local` profile:

- Hermes connects via the **OpenAI-compatible** endpoint (`/v1`, `provider: custom`, `api_key: "ollama-local"`).
- OpenClaw connects via the **native Ollama** endpoint (no `/v1`, `"api": "ollama"`) — the local profile comment says this is for reliable tool calling.

Don't try to "unify" those local transports behind a homegrown MBA router unless you have a clear reason; the divergence is deliberate.

### Web UI exposure

OpenClaw's web UI is part of the gateway. `mba-deploy.sh` flips the live OpenClaw setting to `gateway.bind=lan` and keeps using OpenClaw's shared-token auth, so other devices can reach `http://<mba-host>.local:18789/`.

Hermes is different: its dashboard is a separate process started explicitly with `spark-hermes-dashboard.sh`. Hermes warns in its own code that this UI exposes config and API keys and has no built-in auth. Keep it off by default and only run it on a trusted LAN.

### Config deployment flow

Profiles live in the repo under `profiles/<profile>/{hermes,openclaw}`. `mba-deploy.sh` stages them into `~/.spark-agents/profiles/`, then copies the active profile into `~/.hermes/` and `~/.openclaw/`. **Edits to `~/.hermes/cli-config.yaml` or `~/.openclaw/config.json` directly will be overwritten on the next deploy or profile switch.** Edit the repo copy, commit, re-deploy.

Hosted credentials are intentionally out-of-repo:

- Hermes reads `OPENROUTER_API_KEY` from `~/.hermes/.env`
- OpenClaw reads `OPENROUTER_API_KEY` from `~/.openclaw/.env`

### Model files

Modelfiles in `ollama/` reference absolute paths under `/srv/models/...` on the Spark. This path is deliberate: `/home/carlid` is mode 750 and the `ollama` system user cannot traverse it, so `ollama create` can't read GGUFs from there. `/srv/models` is world-readable and outside `/home` entirely. If you change where GGUFs are downloaded, update both the Modelfile `FROM` line and `MODEL_DIR` in `spark-setup.sh`.
