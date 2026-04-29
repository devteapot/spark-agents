# home-lab

Three-node home lab infrastructure for running local LLMs with agent integration:

| Node | Host | IP | GPU | Role |
|------|------|-----|-----|------|
| **DGX Spark** | `carlid@slopinator-s-1.local` | `192.168.1.96` | GB10 (128 GiB) | vLLM serving — Qwen3.6-35B-A3B FP8 |
| **New Node** | `carlid@slopinator-n1` | `192.168.1.48` | RTX 3090 (24 GiB) | Reserved for future dense/MoE models |
| **MacBook Air** | `sloppy@sloppy-mba.local` | LAN | — | Hermes, OpenClaw, LiteLLM router |

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
git clone git@github.com:devteapot/home-lab.git ~/home-lab
cd ~/home-lab
sudo ./scripts/lab-setup.sh
```

This downloads models under `/srv/models`, builds the vLLM container images, and migrates any legacy systemd units.

### MBA (one-time or after config/script edits)

```bash
git clone git@github.com:devteapot/home-lab.git ~/dev/home-lab
cd ~/dev/home-lab
./scripts/mba-deploy.sh
```

This stages the configs into `~/.home-lab`, restarts local `LiteLLM`, copies the live configs into `~/.hermes` and `~/.openclaw`, and restarts both agents once.

## Daily Workflow

```bash
# Check router, Spark service, and agent processes
lab-status.sh

# Switch back to Spark-local serving
lab-resume.sh

# Free the Spark GPU for non-agent compute (benchmarks, fine-tunes, etc.)
lab-pause.sh
```

`lab-pause.sh` and `lab-resume.sh` do not restart Hermes or OpenClaw. They only flip LiteLLM mode and start/stop the Spark vLLM service.

## Credentials

Hosted routing needs `OPENROUTER_API_KEY`. The scripts look for it in this order:

1. `$OPENROUTER_API_KEY`
2. `~/.home-lab/litellm.env`
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
cd ~/home-lab && git pull
cd spark && docker compose down && docker compose up -d
```
