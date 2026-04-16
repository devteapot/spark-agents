#!/usr/bin/env bash

SPARK_HOST="${SPARK_HOST:-slopinator-s-1.local}"
SPARK_USER="${SPARK_USER:-carlid}"

PATH="${HOME}/.local/bin:${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

SPARK_SUPERGEMMA_V1_URL="http://${SPARK_HOST}:8001/v1"
SPARK_CODER_V1_URL="http://${SPARK_HOST}:8002/v1"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://127.0.0.1:4000}"
LITELLM_V1_URL="${LITELLM_V1_URL:-${LITELLM_BASE_URL}/v1}"

SPARK_AGENTS_HOME="${HOME}/.spark-agents"
LITELLM_RUNTIME_DIR="${SPARK_AGENTS_HOME}/litellm"
LITELLM_ACTIVE_CONFIG="${LITELLM_RUNTIME_DIR}/config.yaml"
LITELLM_AGENT_CONFIG="${LITELLM_RUNTIME_DIR}/agent-mode.yaml"
LITELLM_OFFLOAD_CONFIG="${LITELLM_RUNTIME_DIR}/offload-mode.yaml"
LITELLM_MODE_FILE="${LITELLM_RUNTIME_DIR}/current-mode"
LITELLM_PID_FILE="${LITELLM_RUNTIME_DIR}/litellm.pid"
LITELLM_LOG_FILE="${LITELLM_LOG_FILE:-/tmp/litellm.log}"

SUPERGEMMA_MODEL_ID="AEON-7/supergemma4-26b-abliterated-multimodal-nvfp4"
CODER_MODEL_ID="qwen/qwen3-coder-next"
GENERAL_CLOUD_MODEL_ID="openrouter/google/gemini-2.5-flash"
CODER_CLOUD_MODEL_ID="openrouter/anthropic/claude-sonnet-4-5"

SCRIPT_LABEL="${SCRIPT_LABEL:-spark}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[${SCRIPT_LABEL}]${NC} $*"; }
warn() { echo -e "${YELLOW}[${SCRIPT_LABEL}]${NC} $*"; }
err()  { echo -e "${RED}[${SCRIPT_LABEL}]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        err "Required command not found: ${cmd}"
        return 1
    fi
}

ensure_runtime_dirs() {
    mkdir -p "${SPARK_AGENTS_HOME}" "${LITELLM_RUNTIME_DIR}"
}

read_env_value() {
    local file="$1"
    local key="$2"

    [ -f "${file}" ] || return 1

    python3 - "$file" "$key" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]

for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    name, value = line.split("=", 1)
    if name.strip() != key:
        continue
    value = value.strip().strip('"').strip("'")
    print(value)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

resolve_openrouter_api_key() {
    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        printf '%s\n' "${OPENROUTER_API_KEY}"
        return 0
    fi

    local env_file
    for env_file in \
        "${SPARK_AGENTS_HOME}/litellm.env" \
        "${HOME}/.hermes/.env" \
        "${HOME}/.openclaw/.env"
    do
        if read_env_value "${env_file}" "OPENROUTER_API_KEY" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

require_openrouter_api_key() {
    local key
    key="$(resolve_openrouter_api_key)" || {
        err "OPENROUTER_API_KEY not found. Checked \$OPENROUTER_API_KEY, ${SPARK_AGENTS_HOME}/litellm.env, ~/.hermes/.env, and ~/.openclaw/.env."
        return 1
    }

    printf '%s\n' "${key}"
}

ensure_litellm_installed() {
    if command -v docker > /dev/null 2>&1; then
        return 0
    fi

    err "Docker is not installed. Install Docker Desktop and try again."
    return 1
}

LITELLM_COMPOSE_FILE="${LITELLM_COMPOSE_FILE:-}"

_litellm_compose_file() {
    if [ -n "${LITELLM_COMPOSE_FILE}" ]; then
        printf '%s\n' "${LITELLM_COMPOSE_FILE}"
        return 0
    fi

    local candidates=(
        "${SPARK_AGENTS_HOME}/litellm/docker-compose.yaml"
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/litellm/docker-compose.yaml"
    )
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done

    err "Cannot find litellm/docker-compose.yaml"
    return 1
}

litellm_is_running() {
    docker container inspect spark-litellm > /dev/null 2>&1 && \
        [ "$(docker container inspect -f '{{.State.Running}}' spark-litellm 2>/dev/null)" = "true" ]
}

stop_litellm() {
    if ! docker container inspect spark-litellm > /dev/null 2>&1; then
        return 0
    fi

    log "Stopping LiteLLM container..."
    docker stop spark-litellm > /dev/null 2>&1 || true
    docker rm spark-litellm > /dev/null 2>&1 || true

    # Clean up any legacy bare-process litellm
    pkill -9 -f "litellm --config" 2>/dev/null || true
    rm -f "${LITELLM_PID_FILE}"
}

wait_for_models_endpoint() {
    local base_url="$1"
    local label="$2"
    local timeout="${3:-60}"
    local i

    for i in $(seq 1 "${timeout}"); do
        if curl -sf --connect-timeout 3 "${base_url}/models" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    err "${label} did not answer ${base_url}/models within ${timeout}s."
    return 1
}

healthcheck_chat_completion() {
    local base_url="$1"
    local model="$2"
    local label="$3"
    local payload

    payload="$(python3 - "$model" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [
        {"role": "user", "content": "Reply with the single word: ready"}
    ],
    "temperature": 0,
    "max_tokens": 8
}))
PY
)"

    if curl -sf --connect-timeout 10 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${base_url}/chat/completions" > /dev/null 2>&1
    then
        return 0
    fi

    err "${label} failed a basic chat completion health check."
    return 1
}

healthcheck_tool_call() {
    local base_url="$1"
    local model="$2"
    local label="$3"
    local payload

    payload="$(python3 - "$model" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [
        {"role": "user", "content": "Call the ping tool once."}
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "ping",
                "description": "Return a ping acknowledgement.",
                "parameters": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": False
                }
            }
        }
    ],
    "tool_choice": "required",
    "temperature": 0,
    "max_tokens": 64
}))
PY
)"

    if curl -sf --connect-timeout 10 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${base_url}/chat/completions" > /dev/null 2>&1
    then
        return 0
    fi

    err "${label} failed a tool-calling health check."
    return 1
}

router_mode_config_path() {
    local mode="$1"

    case "${mode}" in
        agent-mode) printf '%s\n' "${LITELLM_AGENT_CONFIG}" ;;
        offload-mode|benchmark-mode) printf '%s\n' "${LITELLM_OFFLOAD_CONFIG}" ;;
        *)
            err "Unknown LiteLLM mode: ${mode}"
            return 1
            ;;
    esac
}

restart_litellm() {
    local mode="$1"
    local source_config
    local openrouter_key
    local compose_file

    ensure_runtime_dirs
    ensure_litellm_installed

    compose_file="$(_litellm_compose_file)" || return 1

    source_config="$(router_mode_config_path "${mode}")"
    [ -f "${source_config}" ] || {
        err "Missing LiteLLM runtime config: ${source_config}"
        return 1
    }

    if openrouter_key="$(resolve_openrouter_api_key 2>/dev/null)"; then
        :
    elif [ "${mode}" = "agent-mode" ]; then
        openrouter_key="missing-openrouter-key"
        warn "OPENROUTER_API_KEY not found; starting agent-mode with local routes only."
        warn "Hidden cloud fallbacks will stay unavailable until a real key is configured."
    else
        require_openrouter_api_key > /dev/null || return 1
        openrouter_key="$(resolve_openrouter_api_key)"
    fi

    cp "${source_config}" "${LITELLM_ACTIVE_CONFIG}"
    printf '%s\n' "${mode}" > "${LITELLM_MODE_FILE}"

    stop_litellm

    log "Starting LiteLLM in ${mode}..."
    LITELLM_CONFIG_PATH="${LITELLM_RUNTIME_DIR}" \
    OPENROUTER_API_KEY="${openrouter_key}" \
        docker compose -f "${compose_file}" up -d 2>&1 | grep -v "^$" || true

    wait_for_models_endpoint "${LITELLM_V1_URL}" "LiteLLM" 30 || {
        err "LiteLLM container logs:"
        docker logs spark-litellm --tail 30 2>&1 || true
        return 1
    }
}

current_router_mode() {
    if [ -f "${LITELLM_MODE_FILE}" ]; then
        cat "${LITELLM_MODE_FILE}"
    else
        printf 'unknown\n'
    fi
}

spark_remote_sudo() {
    ssh -tt "${SPARK_USER}@${SPARK_HOST}" "sudo bash -se"
}

print_openai_models() {
    local models_json="$1"

    python3 - "${models_json}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
models = data.get("data", [])
if not models:
    print("  No models reported.")
else:
    for model in models:
        print(f"  {model.get('id', '?')}")
PY
}
