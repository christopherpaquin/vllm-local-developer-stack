#!/usr/bin/env bash
# =============================================================================
# setup-cline-cli.sh
# Configures the Cline CLI tool to connect to your local vLLM custom API endpoint.
# Updates ~/.cline/data/settings/providers.json
#
# Usage:
#   bash scripts/deploy/setup-cline-cli.sh [vllm-host-ip:port]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

VLLM_HOST_ARG="${1:-}"

# ---------------------------------------------------------------------------
# Path resolutions
# ---------------------------------------------------------------------------
CONFIG_DIR="${HOME}/.cline/data/settings"
CONFIG_FILE="${CONFIG_DIR}/providers.json"
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Default values if .env is missing or has defaults
BIND_HOST="localhost"
PORT="8000"
MODEL_ID="qwen2.5-coder-14b-awq"

ENV_FILE="$(dirname "$0")/../../scripts/deploy/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # Squelch unbound variable errors by sourcing with fallbacks
  set +u
  ENV_BIND_HOST=$(grep -E "^BIND_HOST=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  ENV_PORT=$(grep -E "^PORT=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  ENV_MODEL_NAME=$(grep -E "^SERVED_MODEL_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  set -u

  [[ -n "${ENV_BIND_HOST}" ]] && BIND_HOST="${ENV_BIND_HOST}"
  [[ -n "${ENV_PORT}" ]] && PORT="${ENV_PORT}"
  [[ -n "${ENV_MODEL_NAME}" ]] && MODEL_ID="${ENV_MODEL_NAME}"
fi

# Override values from command-line argument if passed
if [[ -n "${VLLM_HOST_ARG}" ]]; then
  if [[ "${VLLM_HOST_ARG}" =~ : ]]; then
    BIND_HOST=$(echo "${VLLM_HOST_ARG}" | cut -d: -f1)
    PORT=$(echo "${VLLM_HOST_ARG}" | cut -d: -f2)
  else
    BIND_HOST="${VLLM_HOST_ARG}"
  fi
fi

# Treat BIND_HOST="0.0.0.0" as localhost for client convenience
if [[ "${BIND_HOST}" == "0.0.0.0" ]]; then
  BIND_HOST="localhost"
fi

step "STEP 1/3 — Dependency Check"
if ! command -v python3 &>/dev/null; then
  fail "python3 is required but not installed."
fi
ok "python3 is available."

step "STEP 2/3 — Resolve vLLM Configuration"
VLLM_API_BASE="http://${BIND_HOST}:${PORT}/v1"
info "vLLM server target: ${BIND_HOST}:${PORT}"

# Query the live model ID from vLLM endpoint if reachable
info "Checking live model ID at http://${BIND_HOST}:${PORT}/v1..."
LIVE_MODEL=""
if command -v curl &>/dev/null && command -v jq &>/dev/null; then
  if LIVE_MODEL=$(curl -s --max-time 3 "${VLLM_API_BASE}/models" | jq -r '.data[0].id' 2>/dev/null) && [[ -n "${LIVE_MODEL}" ]] && [[ "${LIVE_MODEL}" != "null" ]]; then
    MODEL_ID="${LIVE_MODEL}"
    ok "Resolved model name from live server: ${MODEL_ID}"
  else
    warn "vLLM server not responding yet. Falling back to configured default: ${MODEL_ID}"
  fi
else
  warn "curl or jq missing. Skipping live check, falling back to configured: ${MODEL_ID}"
fi

step "STEP 3/3 — Configure Cline CLI Settings"
if [[ ! -d "${CONFIG_DIR}" ]]; then
  mkdir -p "${CONFIG_DIR}"
  ok "Created Cline configuration directory: ${CONFIG_DIR}"
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  info "Backing up ${CONFIG_FILE} to ${BACKUP_FILE}..."
  cp "${CONFIG_FILE}" "${BACKUP_FILE}"
  ok "Backup saved: ${BACKUP_FILE}"
fi

python3 - <<PYEOF
import json, os, datetime, sys

config_path = "${CONFIG_FILE}"
model_id = "${MODEL_ID}"
api_base = "http://${BIND_HOST}:${PORT}/v1"

# Default schema skeleton
config = {
    "version": 1,
    "lastUsedProvider": "openai",
    "providers": {}
}

# Load existing configuration if it exists and is valid
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            existing_config = json.load(f)
            if isinstance(existing_config, dict):
                config.update(existing_config)
    except Exception as e:
        print(f"  [WARN] Failed to parse existing {config_path}: {e}. Initializing a new configuration.")

# Ensure structure is sound
if "providers" not in config:
    config["providers"] = {}

# Timestamp
now_str = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

# Build new openai provider settings block
config["providers"]["openai"] = {
    "settings": {
        "provider": "openai",
        "model": model_id,
        "openAiBaseUrl": api_base,
        "openAiApiKey": "dummy",  # pragma: allowlist secret
        "openAiModelId": model_id
    },
    "updatedAt": now_str,
    "tokenSource": "manual"
}

# Build new openai-compatible provider settings block
config["providers"]["openai-compatible"] = {
    "settings": {
        "provider": "openai-compatible",
        "model": model_id,
        "baseUrl": api_base,
        "apiKey": "dummy"  # pragma: allowlist secret
    },
    "updatedAt": now_str,
    "tokenSource": "manual"
}

# Set as last used provider
config["lastUsedProvider"] = "openai-compatible"

# Write back to file
try:
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"  [OK] Successfully updated {config_path}")
except Exception as e:
    print(f"  [ERROR] Failed to write {config_path}: {e}")
    sys.exit(1)
PYEOF

echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   Cline CLI configured for local vLLM.                       ║${RESET}"
echo -e "${GREEN}${BOLD}║   Run 'cline' in your terminal to start coding!              ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
