#!/usr/bin/env bash
# =============================================================================
# install-prereqs.sh
# Idempotent validator & installer for all vLLM deployment prerequisites.
# Philosophy: Validator-first. Never blindly overwrites a working driver stack.
# =============================================================================
set -euo pipefail

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Privilege guard ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root (sudo $0)."
fi

# =============================================================================
# STEP 1 — NVIDIA GPU Driver
# =============================================================================
step "STEP 1/4 — NVIDIA GPU Driver"

if command -v nvidia-smi &>/dev/null; then
  DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  ok "nvidia-smi found. Driver version: ${DRIVER_VERSION}. Skipping driver installation."
else
  warn "nvidia-smi not found. Proceeding with headless driver installation..."

  info "Installing ubuntu-drivers-common..."
  apt-get update -qq
  apt-get install -y ubuntu-drivers-common

  info "Detecting recommended GPU driver..."
  ubuntu-drivers install --gpgpu

  warn "═══════════════════════════════════════════════════════════"
  warn "  A SYSTEM REBOOT IS REQUIRED to activate the GPU driver."
  warn "  After reboot, re-run this script to continue setup."
  warn "  Command: sudo reboot"
  warn "═══════════════════════════════════════════════════════════"
  exit 0
fi

# =============================================================================
# STEP 2 — Docker CE
# =============================================================================
step "STEP 2/4 — Docker CE"

if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version)
  ok "Docker already installed: ${DOCKER_VERSION}. Skipping."
else
  warn "Docker not found. Installing Docker CE from official repositories..."

  # Remove any legacy packages that may conflict
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
  done

  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release

  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add the Docker stable repository
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Enable and start Docker service
  systemctl enable --now docker

  ok "Docker CE installed and service started."
fi

# Verify docker compose plugin
if ! docker compose version &>/dev/null; then
  warn "docker compose plugin not detected. Installing..."
  apt-get install -y docker-compose-plugin
fi
ok "Docker Compose plugin: $(docker compose version --short)"

# =============================================================================
# STEP 3 — NVIDIA Container Toolkit
# =============================================================================
step "STEP 3/4 — NVIDIA Container Toolkit"

if dpkg -l | grep -q nvidia-container-toolkit 2>/dev/null; then
  NCT_VERSION=$(dpkg -l nvidia-container-toolkit | awk '/nvidia-container-toolkit/{print $3}')
  ok "nvidia-container-toolkit already installed: ${NCT_VERSION}."
else
  warn "nvidia-container-toolkit not found. Installing..."

  # Add NVIDIA Container Toolkit repository
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update -qq
  apt-get install -y nvidia-container-toolkit
  ok "nvidia-container-toolkit installed."
fi

# --- Verify NVIDIA runtime is registered in Docker daemon.json ---------------
DAEMON_JSON="/etc/docker/daemon.json"
info "Verifying NVIDIA runtime is registered in ${DAEMON_JSON}..."

NEEDS_RUNTIME_CONFIG=false

if [[ ! -f "${DAEMON_JSON}" ]]; then
  warn "${DAEMON_JSON} does not exist. Creating..."
  NEEDS_RUNTIME_CONFIG=true
elif ! jq -e '.runtimes.nvidia' "${DAEMON_JSON}" &>/dev/null; then
  warn "NVIDIA runtime not found in ${DAEMON_JSON}. Injecting..."
  NEEDS_RUNTIME_CONFIG=true
else
  ok "NVIDIA runtime already configured in ${DAEMON_JSON}."
fi

if [[ "${NEEDS_RUNTIME_CONFIG}" == "true" ]]; then
  # Generate NVIDIA runtime configuration via toolkit helper
  nvidia-ctk runtime configure --runtime=docker

  info "Restarting Docker daemon to apply runtime changes..."
  systemctl restart docker
  ok "Docker daemon restarted with NVIDIA runtime support."
fi

# Sanity-check: confirm the runtime block is now present
if jq -e '.runtimes.nvidia' "${DAEMON_JSON}" &>/dev/null; then
  ok "Confirmed: NVIDIA runtime present in ${DAEMON_JSON}."
else
  fail "Failed to register NVIDIA runtime. Inspect ${DAEMON_JSON} manually."
fi

# =============================================================================
# STEP 4 — System Tools
# =============================================================================
step "STEP 4/4 — System Tools (jq, python3, python3-pip, python3-venv)"

TOOLS=(jq python3 python3-pip python3-venv)
MISSING_TOOLS=()

for tool in "${TOOLS[@]}"; do
  if dpkg -l | grep -q "^ii  ${tool}" 2>/dev/null; then
    ok "${tool} — already installed."
  else
    warn "${tool} — not found, queuing for installation."
    MISSING_TOOLS+=("${tool}")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  info "Installing missing tools: ${MISSING_TOOLS[*]}"
  apt-get update -qq
  apt-get install -y "${MISSING_TOOLS[@]}"
  ok "All missing tools installed."
fi

# Verify python3 is callable and report version
PYTHON_VERSION=$(python3 --version 2>&1)
ok "Python runtime: ${PYTHON_VERSION}"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║       All prerequisites validated and satisfied.         ║${RESET}"
echo -e "${GREEN}${BOLD}║   Next step: sudo bash scripts/validate-system.sh        ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
