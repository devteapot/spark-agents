# spark-agents

Two-machine agent infrastructure with:

- **DGX Spark** (GB10, 128 GiB unified memory) running a local `vLLM` model server via Docker Compose on CUDA 13.2 + vLLM 0.19.1 + PyTorch 2.11 with native SM121 support
- **MacBook Air** running Hermes, OpenClaw, and a local `LiteLLM` router

## Architecture

```text
MBA (sloppy@sloppy-mba.local)
  Hermes   \
            -> LiteLLM (127.0.0.1:4000/v1)
  OpenClaw /

LiteLLM routes:
  agent-mode   -> Spark vLLM SuperGemma :8001 (general)
  offload-mode -> OpenRouter hosted models (Spark GPU free for other compute)
```

Stable logical model ID exposed to both agents:

- `general`

Hidden cloud alias for hosted fallback:

- `general-cloud`

## Model

Spark-local (single model, 92% GPU utilization):

| Role | Model | HF Repo | Weights | Quant | Context | Slots |
|---|---|---|---|---|---|---|
| `general` | SuperGemma4 26B MoE | `AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4` | 16 GiB | NVFP4 (modelopt) | 256K | 8 |

KV cache: fp8, ~800K tokens total capacity, ~3 concurrent requests at full 256K context.

Hosted offload-mode model:

- `openrouter/google/gemini-2.5-flash` for `general`

## Setup

### Spark (one-time)

```bash
git clone git@github.com:devteapot/spark-agents.git ~/spark-agents
cd ~/spark-agents
sudo ./scripts/spark-setup.sh
```

This downloads the SuperGemma model repo under `/srv/models`, builds the vLLM container images, and migrates any legacy systemd units.

### MBA (one-time or after config/script edits)

```bash
git clone git@github.com:devteapot/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/mba-deploy.sh
```

This stages the configs into `~/.spark-agents`, restarts local `LiteLLM`, copies the live configs into `~/.hermes` and `~/.openclaw`, and restarts both agents once.

## Daily Workflow

```bash
# Check router, Spark service, and agent processes
spark-status.sh

# Switch back to Spark-local serving
spark-resume.sh

# Free the Spark GPU for non-agent compute (benchmarks, fine-tunes, etc.)
spark-pause.sh
```

`spark-pause.sh` and `spark-resume.sh` do not restart Hermes or OpenClaw. They only flip LiteLLM mode and start/stop the Spark vLLM service.

## Credentials

Hosted routing needs `OPENROUTER_API_KEY`. The scripts look for it in this order:

1. `$OPENROUTER_API_KEY`
2. `~/.spark-agents/litellm.env`
3. `~/.hermes/.env`
4. `~/.openclaw/.env`

## Syncing Changes

After editing configs or scripts:

```bash
git add -A && git commit -m "description" && git push
```

On the other machine:

```bash
git pull
```

If the MBA-side configs or scripts changed, rerun:

```bash
./scripts/mba-deploy.sh
```

If the Spark-side compose file changed, pull on the Spark and restart:

```bash
cd ~/spark-agents && git pull
cd spark && docker compose down && docker compose up -d
```
