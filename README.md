# spark-agents

Two-machine agent infrastructure with:

- Spark running local `vLLM` model servers
- MBA running Hermes, OpenClaw, and a local `LiteLLM` router

## Architecture

```text
MBA (sloppy@sloppy-mba.local)
  Hermes   \
            -> LiteLLM (127.0.0.1:4000/v1)
  OpenClaw /

LiteLLM routes:
  agent-mode     -> Spark vLLM SuperGemma (8001)
                 -> Spark vLLM Qwen (8002)
  benchmark-mode -> OpenRouter hosted models
```

Stable logical model IDs exposed to both agents:

- `general`
- `coder`

Hidden cloud aliases stay available behind the router for hosted escape hatches:

- `general-cloud`
- `coder-cloud`

## Models

Spark-local models:

- `AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4`
- `Qwen/Qwen3-Coder-Next-FP8`

Hosted benchmark-mode models:

- `openrouter/google/gemini-2.5-flash` for `general`
- `openrouter/anthropic/claude-sonnet-4-5` for `coder`

## Setup

### Spark (one-time)

```bash
git clone git@github.com:carlid-dev/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/spark-setup.sh
```

This installs the Spark-side `vLLM` runtime, downloads both model repos under `/srv/models`, applies the required SuperGemma NVFP4 patches, and installs:

- `vllm-supergemma.service`
- `vllm-qwen.service`

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

# Free the Spark for direct benchmarking
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
