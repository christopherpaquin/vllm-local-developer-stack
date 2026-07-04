#!/usr/bin/env bash
# =============================================================================
# setup-aider.sh
# Automated Aider configuration hook.
# Injects the vLLM endpoint and model into Aider configuration files (.aider.conf.yml).
# Supports updating existing files or creating new ones.
#
# Usage:
#   bash scripts/deploy/setup-aider.sh [vllm-host] [-y|--yes]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Options -------------------------------------------------------------
ASSUME_YES=false
VLLM_HOST_ARG=""
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      echo "Usage: bash scripts/deploy/setup-aider.sh [vllm-host] [-y|--yes]"
      echo "  vllm-host   Optional host[:port] of the vLLM server."
      echo "  -y, --yes   Auto-confirm prompts."
      exit 0
      ;;
    -*) ;;
    *) VLLM_HOST_ARG="${arg}" ;;
  esac
done

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  local reply
  if [[ -e /dev/tty ]]; then
    read -r -p "$(echo -e "${YELLOW}?${RESET} ${prompt} [y/N] ")" reply < /dev/tty || reply=""
  else
    read -r -p "$(echo -e "${YELLOW}?${RESET} ${prompt} [y/N] ")" reply || reply=""
  fi
  [[ "${reply}" =~ ^[Yy]$ ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# =============================================================================
# STEP 1 — Verify Aider Installation
# =============================================================================
step "STEP 1/3 — Aider Installation Check"

AIDER_INSTALLED=true
if ! command -v aider &>/dev/null; then
  AIDER_INSTALLED=false
  warn "Aider is not installed."

  if confirm "Would you like to install Aider now?"; then
    info "Attempting to install Aider..."

    if command -v pipx &>/dev/null; then
      info "Installing Aider via pipx..."
      pipx install aider-chat
      AIDER_INSTALLED=true
    elif command -v pip3 &>/dev/null; then
      info "pipx not found. Installing Aider via pip3..."
      if python3 -c "import sys; print(hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix))" | grep -q "True"; then
        python3 -m pip install aider-chat
      else
        # Try user install
        if python3 -m pip install --help | grep -q "break-system-packages"; then
          python3 -m pip install --user aider-chat --break-system-packages
        else
          python3 -m pip install --user aider-chat
        fi
      fi
      AIDER_INSTALLED=true
    else
      fail "Could not find 'pipx' or 'pip3' to install Aider. Please install it manually."
    fi
  else
    info "Installation declined. Stopping configuration."
    exit 0
  fi
fi

if [[ "${AIDER_INSTALLED}" == "true" ]]; then
  # Verify aider command works/exists in PATH (if just installed with pip/pipx we might need ~/.local/bin in path)
  if ! command -v aider &>/dev/null && [[ -f "${HOME}/.local/bin/aider" ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  ok "Aider is installed ($(aider --version 2>/dev/null || echo 'version unknown'))."
fi

# =============================================================================
# STEP 2 — Resolve vLLM Server Settings (IP/Port/Model)
# =============================================================================
step "STEP 2/3 — Resolve vLLM Configuration"

# Resolve Host, Port, and Model
BIND_HOST=""
PORT=""
MODEL_ID=""
MAX_MODEL_LEN="6144"

if [[ -n "${VLLM_HOST_ARG}" ]]; then
  if [[ "${VLLM_HOST_ARG}" == *:* ]]; then
    BIND_HOST="${VLLM_HOST_ARG%%:*}"
    PORT="${VLLM_HOST_ARG##*:}"
  else
    BIND_HOST="${VLLM_HOST_ARG}"
    PORT="8000"
  fi
  info "Using vLLM server address from command line argument: ${BIND_HOST}:${PORT}"
else
  # Read from .env if present
  ENV_HOST=""
  ENV_PORT=""
  if [[ -f "${ENV_FILE}" ]]; then
    ENV_HOST=$(grep '^BIND_HOST=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    ENV_PORT=$(grep '^PORT=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  fi

  # Determine BIND_HOST
  if [[ -n "${ENV_HOST}" ]]; then
    SUGGESTED_HOST="${ENV_HOST}"
    if [[ "${ENV_HOST}" == "0.0.0.0" ]]; then
      SUGGESTED_HOST="127.0.0.1"
    fi
    if confirm "Use vLLM host IP found in scripts/deploy/.env (${SUGGESTED_HOST})?"; then
      BIND_HOST="${SUGGESTED_HOST}"
    fi
  fi

  if [[ -z "${BIND_HOST}" ]]; then
    if [[ "${ASSUME_YES}" == "true" ]]; then
      BIND_HOST="127.0.0.1"
    else
      reply=""
      if [[ -e /dev/tty ]]; then
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server IP/hostname [default: 127.0.0.1]: ")" reply < /dev/tty || reply=""
      else
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server IP/hostname [default: 127.0.0.1]: ")" reply || reply=""
      fi
      BIND_HOST="${reply:-127.0.0.1}"
    fi
  fi

  # Determine PORT
  if [[ -n "${ENV_PORT}" ]]; then
    if confirm "Use vLLM port found in scripts/deploy/.env (${ENV_PORT})?"; then
      PORT="${ENV_PORT}"
    fi
  fi

  if [[ -z "${PORT}" ]]; then
    if [[ "${ASSUME_YES}" == "true" ]]; then
      PORT="8000"
    else
      reply=""
      if [[ -e /dev/tty ]]; then
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server port [default: 8000]: ")" reply < /dev/tty || reply=""
      else
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server port [default: 8000]: ")" reply || reply=""
      fi
      PORT="${reply:-8000}"
    fi
  fi
fi

# Load other defaults/configs from .env if it exists
if [[ -f "${ENV_FILE}" ]]; then
  MAX_MODEL_LEN=$(grep '^MAX_MODEL_LEN=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "6144")
  MODEL_ID=$(grep '^SERVED_MODEL_NAME=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  if [[ -z "${MODEL_ID}" ]]; then
    MODEL_ID=$(grep '^MODEL=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  fi
fi

VLLM_HOST="${BIND_HOST}:${PORT}"
VLLM_API_BASE="http://${VLLM_HOST}/v1"

# Try to query the live server for the actual served model ID
info "Checking live model ID at ${VLLM_API_BASE}..."
LIVE_MODEL=$(python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.urlopen('${VLLM_API_BASE}/models', timeout=3)
    d = json.loads(r.read())
    print(d['data'][0]['id'])
except Exception:
    sys.exit(1)
" 2>/dev/null || echo "")

if [[ -n "${LIVE_MODEL}" ]]; then
  MODEL_ID="${LIVE_MODEL}"
  ok "Resolved model name from live server: ${MODEL_ID}"
else
  MODEL_ID="${MODEL_ID:-qwen2.5-coder-14b-awq}"
  warn "vLLM server is not reachable at ${VLLM_API_BASE}."
  warn "Using fallback model name: ${MODEL_ID}"
fi

AIDER_MODEL="openai/${MODEL_ID}"

# =============================================================================
# STEP 3 — Configure Aider (.aider.conf.yml and model metadata)
# =============================================================================
step "STEP 3/3 — Configure Aider"

LOCAL_CONFIG="${REPO_ROOT}/.aider.conf.yml"
GLOBAL_CONFIG="${HOME}/.aider.conf.yml"

CONFIG_FILES=()

# Determine which files to update
if [[ -f "${LOCAL_CONFIG}" ]]; then
  if confirm "Found existing project-specific config at ${LOCAL_CONFIG}. Update its vLLM IP/port?"; then
    CONFIG_FILES+=("${LOCAL_CONFIG}")
  fi
fi

if [[ -f "${GLOBAL_CONFIG}" ]]; then
  if confirm "Found existing global config at ${GLOBAL_CONFIG}. Update its vLLM IP/port?"; then
    CONFIG_FILES+=("${GLOBAL_CONFIG}")
  fi
fi

# If no existing configs are selected/exist, prompt to create one
if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
  if confirm "Create a project-specific config at ${LOCAL_CONFIG}? (No will prompt to create a global config)"; then
    CONFIG_FILES+=("${LOCAL_CONFIG}")
  else
    if confirm "Create a global config at ${GLOBAL_CONFIG}?"; then
      CONFIG_FILES+=("${GLOBAL_CONFIG}")
    fi
  fi
fi

if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
  info "No configuration file was created or modified."
  exit 0
fi

# Update/Create each config file using Python to preserve comments and other keys
for config_path in "${CONFIG_FILES[@]}"; do
  info "Configuring Aider in ${config_path}..."

  python3 - <<PYEOF
import os, re, sys

config_path = "${config_path}"
api_base = "${VLLM_API_BASE}"
api_key = "dummy"  # pragma: allowlist secret
model_name = "${AIDER_MODEL}"

lines = []
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print(f"  [ERROR] Failed to read {config_path}: {e}", file=sys.stderr)
        sys.exit(1)

keys_to_update = {
    "openai-api-base": api_base,
    "openai-api-key": api_key,
    "model": model_name
}

updated_keys = set()
new_lines = []

for line in lines:
    matched = False
    # Look for patterns like "key: value" or "# key: value"
    # and preserve any comment or indentation prefix
    m = re.match(r"^(\s*(?:#\s*)?)([\w-]+)\s*:\s*(.*)$", line)
    if m:
        prefix, key, old_val = m.groups()
        # strip any leading comment from key if we are updating it,
        # but keep indentation
        clean_key = key.strip()
        if clean_key in keys_to_update:
            indent = prefix.replace("#", "").rstrip()
            new_lines.append(f"{indent}{clean_key}: {keys_to_update[clean_key]}\n")
            updated_keys.add(clean_key)
            matched = True

    if not matched:
        new_lines.append(line)

# Append any keys that weren't present in the original file
for key, val in keys_to_update.items():
    if key not in updated_keys:
        new_lines.append(f"{key}: {val}\n")

try:
    with open(config_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    print(f"  [OK] Successfully updated {config_path}")
except Exception as e:
    print(f"  [ERROR] Failed to write {config_path}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  # Write/Update model metadata json to suppress unknown model warning
  metadata_path="$(dirname "${config_path}")/.aider.model.metadata.json"
  info "Configuring Aider model metadata in ${metadata_path}..."

  python3 - <<PYEOF
import os, json, sys

metadata_path = "${metadata_path}"
model_key = "${AIDER_MODEL}"
try:
    max_len = int("${MAX_MODEL_LEN}")
except ValueError:
    max_len = 6144

data = {}
if os.path.exists(metadata_path):
    try:
        with open(metadata_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        # Start fresh if parsing fails
        data = {}

data[model_key] = {
    "max_tokens": max_len,
    "max_input_tokens": max_len,
    "max_output_tokens": min(max_len, 4096),
    "input_cost_per_token": 0.0,
    "output_cost_per_token": 0.0,
    "litellm_provider": "openai",
    "mode": "chat"
}

try:
    with open(metadata_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  [OK] Successfully updated {metadata_path}")
except Exception as e:
    print(f"  [ERROR] Failed to write {metadata_path}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

done

ok "Aider configuration complete."

echo ""
echo -e "${BOLD}To start Aider with the local vLLM server, run:${RESET}"
echo -e "  ${GREEN}aider${RESET}"
echo ""
