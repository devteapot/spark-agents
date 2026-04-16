# spark-agents

Two-machine agent infrastructure with:

- **DGX Spark** (GB10, 128 GiB unified memory) running two local `vLLM` model servers on CUDA 13.2 + vLLM 0.19.1 + PyTorch 2.11 with native SM121 support
- **MacBook Air** running Hermes, OpenClaw, and a local `LiteLLM` router

## Architecture

```text
MBA (sloppy@sloppy-mba.local)
  Hermes   \
            -> LiteLLM (127.0.0.1:4000/v1)
  OpenClaw /

LiteLLM routes:
  agent-mode   -> Spark vLLM SuperGemma :8001 (general)
               -> Spark vLLM Qwen3-Coder-Next :8002 (coder)
  offload-mode -> OpenRouter hosted models (Spark GPU free for other compute)
```

Stable logical model IDs exposed to both agents:

- `general`
- `coder`

Hidden cloud aliases stay available behind the router for hosted escape hatches:

- `general-cloud`
- `coder-cloud`

## Models

Spark-local models (co-resident, GPU budget 0.85):

| Role | Model | HF Repo | VRAM | Quant |
|---|---|---|---|---|
| `general` | SuperGemma4 26B MoE | `AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4` | 16 GiB | NVFP4 (modelopt) |
| `coder` | Qwen3-Coder-Next 80B/3B-A MoE | `GadflyII/Qwen3-Coder-Next-NVFP4` | 44 GiB | NVFP4 (compressed-tensors) |

Hosted offload-mode models:

- `openrouter/google/gemini-2.5-flash` for `general`
- `openrouter/anthropic/claude-sonnet-4-5` for `coder`

## Setup

### Spark (one-time)

```bash
git clone git@github.com:carlid-dev/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/spark-setup.sh
```

This downloads both model repos under `/srv/models`, builds the Spark-side `vLLM` container images, and installs:

- `vllm-supergemma.service`
- `vllm-coder.service`

The two Spark services still bind directly on the host at `:8001` and `:8002`, but they now run as Docker containers under systemd instead of using a host-managed Python runtime.

### MBA (one-time or after config/script edits)

```bash
git clone git@github.com:carlid-dev/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/mba-deploy.sh
```

This stages the configs into `~/.spark-agents`, restarts local `LiteLLM`, copies the live configs into `~/.hermes` and `~/.openclaw`, and restarts both agents once.

## Daily Workflow

```bash
# Check router, Spark services, and agent processes
spark-status.sh

# Switch back to Spark-local serving
spark-resume.sh

# Free the Spark GPU for non-agent compute (benchmarks, fine-tunes, etc.)
spark-pause.sh
```

`spark-pause.sh` and `spark-resume.sh` do not restart Hermes or OpenClaw. They only flip LiteLLM mode and start/stop the Spark-local `vLLM` services.

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
