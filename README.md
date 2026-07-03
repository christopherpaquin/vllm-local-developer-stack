# vllm-containerized-deploy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-blue?logo=docker)](https://docs.docker.com/compose/)
[![Python](https://img.shields.io/badge/Python-3.12-blue?logo=python)](https://www.python.org/)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=shellcheck)](https://github.com/koalaman/shellcheck)
[![NVIDIA CUDA](https://img.shields.io/badge/CUDA-12.x-green?logo=nvidia)](https://developer.nvidia.com/cuda-zone)
[![vLLM](https://img.shields.io/badge/vLLM-Supported-orange)](https://github.com/vllm-project/vllm)

> Production-grade automation for self-hosting **Qwen2.5-Coder-32B-Instruct-AWQ** on a dual-GPU RTX 3060 setup using vLLM with Tensor Parallelism.

---

## Hardware Target

| Component | Specification |
|-----------|--------------|
| GPUs | 2× NVIDIA RTX 3060 12GB |
| Total VRAM | 24 GB |
| Parallelism | Tensor Parallel (size=2) |
| Host OS | Ubuntu 22.04 LTS |
| Model | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` |
| Quantization | AWQ (4-bit activation-aware) |
| Context | 16,384 tokens (capped for KV cache budget) |

---

## Repository Structure

```
vllm-containerized-deploy/
├── .gitignore                      # Git ignore patterns (ignores WORKLOG.md, deploy/.env, test results, environments)
├── .pre-commit-config.yaml         # Pre-commit framework configurations
├── README.md                       # Comprehensive setup and operations documentation
├── deploy/
│   ├── docker-compose.yml          # vLLM service definition with healthcheck
│   └── .env.example                # Annotated parameter reference
└── scripts/
    ├── install-prereqs.sh          # Idempotent dependency installer
    ├── validate-system.sh          # Pre-flight hardware validation
    ├── tune-inference.sh           # Hardware-sensing config generator
    ├── validate-vram.sh            # Live startup telemetry monitor
    ├── setup-continue.sh           # VS Code Continue extension hook
    ├── stop.sh                     # Graceful vLLM server teardown wrapper
    ├── snapshot-diagnostics.sh     # Read-only GPU state + log capture (run before stop.sh when debugging)
    ├── check-bottlenecks.sh        # Hardware & OS performance advisor (--json for machine-readable output)
    ├── check-commit-msg-secrets.py # Custom hook for commit-msg secrets validation
    ├── benchmark.sh                # Single-stream token throughput evaluator
    ├── load-test.sh                # Concurrent-request load tester (req/s, latency percentiles)
    └── compare-benchmarks.sh       # Regression detector across benchmark-results/ history
```

`benchmark.sh` and `load-test.sh` each write a timestamped JSON record to
`benchmark-results/` (created on first run) so tuning changes can be
compared over time with `compare-benchmarks.sh`.

---

## Quick Start

Run steps **in order**. Each script validates prerequisites before proceeding.

### Step 1 — Install Prerequisites

Installs NVIDIA drivers (if absent), Docker CE, nvidia-container-toolkit, and system tools. Fully idempotent — safe to re-run.

```bash
sudo bash scripts/install-prereqs.sh
```

> ⚠ If drivers were just installed, **reboot first**, then re-run the script.

---

### Step 2 — Validate System Hardware

Checks Docker ↔ GPU connectivity, PCIe link quality (Gen/Width), and display server VRAM impact on GPU 0.

```bash
bash scripts/validate-system.sh
```

**What it checks:**

| Check | Pass Condition |
|-------|---------------|
| Docker GPU access | Container sees all GPUs via `nvidia` runtime |
| PCIe Gen | `current` == `max` for each GPU |
| PCIe Width | `current` == `max` for each GPU |
| Idle VRAM (GPU 0) | < 800 MiB (no display server consuming budget) |

**If a display server is detected on GPU 0:**
```bash
# Switch to headless mode before deploying (saves ~600–1500 MiB on GPU 0)
sudo systemctl isolate multi-user.target
```

---

### Step 3 — Generate Tuned Configuration

Queries your GPU topology dynamically and writes a hardware-appropriate `deploy/.env`.

```bash
bash scripts/tune-inference.sh
```

**Parameters auto-calculated:**

| Parameter | Value (24 GiB setup) | Rationale |
|-----------|---------------------|-----------|
| `TENSOR_PARALLEL_SIZE` | 2 | One shard per GPU |
| `GPU_MEMORY_UTILIZATION` | 0.90 | ~1.2 GiB headroom per card |
| `MAX_MODEL_LEN` | 16384 | KV cache stays within VRAM budget |
| `SWAP_SPACE` | 4 GiB | CPU offload buffer for burst traffic |

Review `deploy/.env` before continuing. You may manually adjust any value.

---

### Step 4 — Start Server & Monitor Initialization

Launches the container and monitors VRAM allocation in real-time during the KV cache loading phase.

```bash
bash scripts/validate-vram.sh
```

**What it monitors (every 5s for up to 150s):**
- Per-GPU VRAM usage with ASCII bar visualization
- Container logs parsed for startup signals

| Signal | Action |
|--------|--------|
| `Uvicorn running on...` | ✅ Exit 0 — server ready |
| `CUDA out of memory` | ❌ Exit 1 — prints recovery instructions |
| Timeout (150s) | ⚠ Model still downloading — check `docker logs vllm-coder-server --follow` |

**Manual start (bypassing the monitor):**
```bash
docker compose -f deploy/docker-compose.yml up -d
docker logs vllm-coder-server --follow
```

---

### Step 5 — Configure VS Code Continue Extension

Injects the local vLLM endpoint into `~/.continue/config.json` as both a chat model and tab-autocomplete model. Creates the file with full defaults if it doesn't exist; patches safely if it does (with backup).

```bash
bash scripts/setup-continue.sh
```

After running, reload VS Code (`Ctrl+Shift+P` → **Developer: Reload Window**).

**Configured endpoints:**

| Setting | Value |
|---------|-------|
| Provider | `openai` (OpenAI-compatible) |
| API Base | `http://localhost:8000/v1` |
| Model | Resolved live from `GET /v1/models` if the server is up (typically `qwen2.5-coder-32b-awq`, matching `--served-model-name` in `docker-compose.yml`) — falls back to `MODEL=` from `deploy/.env` with a warning if the server isn't reachable yet |
| Autocomplete | Same resolved model, `max_tokens=512`, `temperature=0.05` |

Following Step 4 before Step 5 (as ordered above) means the server is
already up, so the live-resolved value is what actually gets written —
not the raw HuggingFace model ID.

---

### Step 6 — Benchmark

Validates throughput by sending a multi-step Rust/Tokio programming prompt and reporting tokens/second.

```bash
bash scripts/benchmark.sh
```

**Sample output:**
```
  Run  Elapsed (s)   Prompt tok    Comp tok    Tok/s      Finish
  ────────────────────────────────────────────────────────────────
  1    42.31          387           1024        24.20      length
  2    41.87          387           1024        24.46      length
  3    43.02          387           1024        23.80      length

  ════════════════════════════════════════════════════════════════
  SUMMARY (n=3 runs)
  ════════════════════════════════════════════════════════════════
  Avg prompt tokens                   387
  Avg completion tokens               1024
  Avg generation time                 42.40 s
  Avg throughput                      24.15 tok/s
  Peak throughput                     24.46 tok/s
  Min throughput                      23.80 tok/s
  ════════════════════════════════════════════════════════════════
  Performance tier: ✓ Good (15–30 tok/s)

  Results saved to: benchmark-results/benchmark_20260702T044144Z.json
```

Each run is also saved to `benchmark-results/benchmark_<timestamp>.json` for
later comparison (see Step 7).

---

### Step 7 — Load Test & Track Tuning Changes Over Time (optional)

`benchmark.sh` measures single-stream throughput — one request at a time.
Real usage (multiple editor sessions, multiple users) is concurrent.
`load-test.sh` fires many small requests from several simultaneous workers
and reports aggregate requests/sec, aggregate tokens/sec, and latency
percentiles (p50/p95/p99):

```bash
bash scripts/load-test.sh [concurrency] [duration_seconds]   # defaults: 4, 30
bash scripts/load-test.sh 8 60                                # 8 concurrent clients, 60s
```

It also samples `nvidia-smi`'s per-GPU throttle-reason flags (power cap,
HW/SW thermal slowdown, power brake) once per second for the duration of the
run and reports any that go active — distinct from `check-bottlenecks.sh`'s
point-in-time power-cap check, this catches *actual* throttling as it
happens under sustained concurrent load (e.g. a card that's fine at idle but
thermal-throttles a minute into real traffic).

Every `benchmark.sh` and `load-test.sh` run is saved as a timestamped JSON
record in `benchmark-results/`. After changing `deploy/.env` (via
`tune-inference.sh`) or host tuning (via `check-bottlenecks.sh`'s
recommendations), re-run the same script and diff against the previous
result:

```bash
bash scripts/compare-benchmarks.sh              # latest 2 benchmark.sh runs
bash scripts/compare-benchmarks.sh --load-test   # latest 2 load-test.sh runs
```

It prints a per-metric delta table and exits non-zero if any metric
regressed beyond its threshold (throughput: 10%, latency: 15–20% depending
on percentile) — safe to drop into a personal tuning script or CI job for
GPU tuning iterations.

`benchmark-results/` grows one JSON file per run and is never pruned
automatically. Once it has real history, trim it with:

```bash
bash scripts/compare-benchmarks.sh --prune              # dry run — lists what would be deleted (keeps last 20 of each type)
bash scripts/compare-benchmarks.sh --prune --keep 10     # dry run with a custom retention count
bash scripts/compare-benchmarks.sh --prune --force       # actually delete
```

Dry run is the default since deleting benchmark history is irreversible —
nothing is removed until you pass `--force`.

---

## API Usage

Once the server is running, it exposes a fully OpenAI-compatible API:

```bash
# Chat Completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder-32b-awq",
    "messages": [{"role": "user", "content": "Write a Python async HTTP client"}],
    "max_tokens": 512,
    "temperature": 0.1
  }'

# List loaded models
curl http://localhost:8000/v1/models

# Health check
curl http://localhost:8000/health
```

**OpenAI Python SDK:**
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="dummy",  # vLLM does not enforce API keys by default
)

response = client.chat.completions.create(
    model="qwen2.5-coder-32b-awq",
    messages=[{"role": "user", "content": "Implement a binary search tree in Go"}],
    max_tokens=1024,
    temperature=0.1,
)
print(response.choices[0].message.content)
```

---

## Tuning Reference

### OOM Recovery

If vLLM exits with a CUDA OOM error during initialization:

```bash
# Edit deploy/.env
MAX_MODEL_LEN=8192          # Halve the context window
GPU_MEMORY_UTILIZATION=0.85 # Increase headroom

# Restart
docker compose -f deploy/docker-compose.yml down
bash scripts/validate-vram.sh
```

### PCIe Bandwidth Notes

The RTX 3060 does not support NVLink. All inter-GPU communication for Tensor Parallelism goes over PCIe. A secondary slot running at x4 instead of x16 will reduce NCCL all-reduce bandwidth and may increase latency by 10–25% on large token batches.

To diagnose: run `bash scripts/validate-system.sh` and review the PCIe
table (flags a GPU running below its *own* rated Gen/Width spec), or
`bash scripts/check-bottlenecks.sh` for the more directly relevant check —
it computes actual effective GB/s per link and flags anything below the
Gen3×8 / Gen4×4 floor that Tensor Parallelism's NCCL all-reduce needs,
which a card can fail even while running at its own full rated spec (e.g.
a Gen2×16 slot).

### Display Server Impact

Running a desktop environment while serving a 32B model is a tight fit on 24 GiB. If GPU 0 shows >800 MiB idle usage, the display server is competing with the KV cache:

```bash
# Free GPU 0 before deployment (non-destructive, re-enable with graphical.target)
sudo systemctl isolate multi-user.target

# Re-enable desktop when done
sudo systemctl isolate graphical.target
```

---

## Server Management

```bash
# Stop the server
docker compose -f deploy/docker-compose.yml down
# or: bash scripts/stop.sh   (same thing, plus a post-stop VRAM confirmation table)

# Capture a diagnostic snapshot before stopping (GPU state + recent logs) —
# useful when debugging a crash, OOM, or silent hang. Read-only, never
# modifies GPU/container state.
bash scripts/snapshot-diagnostics.sh [log_lines]   # default: last 50 log lines
# Saved to ~/.local/share/vllm-snapshots/snapshot_<timestamp>.txt

# View live logs
docker compose -f deploy/docker-compose.yml logs -f

# Restart after config change
docker compose -f deploy/docker-compose.yml down
bash scripts/tune-inference.sh  # Regenerate .env if needed
docker compose -f deploy/docker-compose.yml up -d

# Check container health
docker inspect --format='{{.State.Health.Status}}' vllm-coder-server
```

---

## Security Notes

- The server binds to `0.0.0.0:8000` by default. If running on a network-accessible machine, use a firewall rule or change `HOST=127.0.0.1` in `deploy/.env`.
- vLLM does not enforce API key authentication by default. Add `--api-key <secret>` to the command in `docker-compose.yml` to enable it.
- The HuggingFace cache is mounted from the host. Ensure the model cache directory has appropriate permissions.

---

## Development & Code Quality

This repository uses [pre-commit](https://pre-commit.com/) to automate code validation and enforce security best practices before any changes are committed.

### Installed Hooks

1. **Syntax Linting & Formatting**:
   - `trailing-whitespace`: Trims trailing whitespace from files.
   - `end-of-file-fixer`: Ensures files end with a newline.
   - `check-yaml`: Validates YAML syntax (e.g. for `deploy/docker-compose.yml` and `.pre-commit-config.yaml`).
   - `check-json`: Validates JSON syntax.
   - `check-added-large-files`: Blocks accidentally committing large files (e.g. model weights, cached tensors) that shouldn't be tracked in git.
   - `shellcheck`: Runs [ShellCheck](https://github.com/koalaman/shellcheck) on all shell scripts in `scripts/` to catch syntax, portability, and scripting errors.
2. **Security & Secret Detection**:
   - `detect-private-key`: Checks for the presence of private keys.
   - `gitleaks`: Scans staged changes for hardcoded secrets, API keys, or credentials using [Gitleaks](https://github.com/gitleaks/gitleaks).
   - **Custom Commit Message Scanner**: A custom local python script (`scripts/check-commit-msg-secrets.py`) that scans Git commit messages for secrets (e.g., AWS keys, Slack tokens, high-entropy API keys) during the `commit-msg` git hook phase.

### Manual Verification

You can manually run the pre-commit checks on all files in the repository at any time:
```bash
pre-commit run --all-files
```

---

## License

MIT
