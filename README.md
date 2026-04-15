# spark-agents

Multi-model local AI agent infrastructure running on DGX Spark + MacBook Air.

## Architecture

```
┌─────────────────────────────────┐     ┌──────────────────────────────┐
│  MBA (sloppy@sloppy-mba.local) │     │  DGX Spark (carlid@slop...) │
│                                 │     │                              │
│  ┌─────────────┐               │     │  Ollama (0.0.0.0:11434)     │
│  │ Hermes Agent │──────────────────────▶ SuperGemma4 26B Q8     │
│  └─────────────┘               │     │  (general intelligence)      │
│                                 │     │                              │
│  ┌─────────────┐               │     │  Qwen3-Coder-Next Q6_K      │
│  │  OpenClaw    │──────────────────────▶ (coding agent)              │
│  └─────────────┘               │     │                              │
└─────────────────────────────────┘     └──────────────────────────────┘
```

## Models

| Role | Model | Quant | Memory | Speed |
|------|-------|-------|--------|-------|
| General intelligence | SuperGemma4 26B abliterated-multimodal | Q8_0 | ~28 GB | ~45-60 tok/s |
| Coding agent | Qwen3-Coder-Next 80B-A3B | Q6_K | ~65 GB | ~43 tok/s |

## Setup

### Spark (one-time)
```bash
git clone git@github.com:carlid-dev/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/spark-setup.sh
```

### MBA (one-time)
```bash
git clone git@github.com:carlid-dev/spark-agents.git ~/spark-agents
cd ~/spark-agents
./scripts/mba-deploy.sh
```

## Daily Workflow

```bash
# Check status
spark-status.sh

# Switch to agent mode (applies Ollama tuning, loads models, starts agents)
spark-resume.sh

# Switch to benchmark mode (stops agents, restores clean Ollama defaults)
spark-pause.sh
```

## Syncing Changes

After editing configs on either machine:
```bash
git add -A && git commit -m "description" && git push
```

On the other machine:
```bash
git pull
```

For MBA agent configs, re-run `mba-deploy.sh` after pulling to copy configs to `~/.hermes/` and `~/.openclaw/`.
