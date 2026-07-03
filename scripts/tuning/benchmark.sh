#!/usr/bin/env bash
# =============================================================================
# benchmark.sh
# Token throughput evaluator for the local vLLM inference server.
# Sends a rigorous multi-step programming prompt and reports tokens/second.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

ENDPOINT="http://localhost:8000/v1"
HEALTH_URL="${ENDPOINT}/models"

# --- Benchmark rounds: bash scripts/benchmark.sh [n_runs] (default: 3) -------
N_RUNS="${1:-3}"
if ! [[ "${N_RUNS}" =~ ^[0-9]+$ ]] || [[ "${N_RUNS}" -lt 1 ]]; then
  fail "Invalid n_runs '${N_RUNS}'. Usage: bash scripts/benchmark.sh [n_runs]  (must be a positive integer, default: 3)"
fi
export N_RUNS

# --- Repo-relative results dir (historical tracking, same pattern as load-test.sh) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/benchmark-results"
mkdir -p "${RESULTS_DIR}"
RESULT_FILE="${RESULTS_DIR}/benchmark_$(date -u '+%Y%m%dT%H%M%SZ').json"
export RESULT_FILE

# =============================================================================
# STEP 1 — Verify endpoint availability
# =============================================================================
step "STEP 1/3 — Endpoint Availability Check"

info "Usage: bash scripts/benchmark.sh [n_runs]  (running with n_runs=${N_RUNS})"

if ! command -v python3 &>/dev/null; then
  fail "python3 required. Run scripts/install-prereqs.sh first."
fi

info "Checking ${HEALTH_URL} ..."

HTTP_STATUS=$(python3 -c "
import urllib.request, sys
try:
    req = urllib.request.urlopen('${HEALTH_URL}', timeout=5)
    print(req.getcode())
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || {
  fail "Cannot reach ${HEALTH_URL}. Start the server first:\n  bash scripts/validate-vram.sh"
}

if [[ "${HTTP_STATUS}" == "200" ]]; then
  ok "Server is reachable. HTTP ${HTTP_STATUS}."
else
  fail "Unexpected HTTP status ${HTTP_STATUS} from ${HEALTH_URL}."
fi

# =============================================================================
# STEP 2 — Run benchmark
# =============================================================================
step "STEP 2/3 — Running Benchmark (max_tokens=1024)"

info "Sending rigorous multi-step programming prompt..."
echo ""

python3 - <<'PYEOF'
import json
import os
import time
import urllib.request
import urllib.error
import sys

ENDPOINT        = "http://localhost:8000/v1/chat/completions"
MAX_TOKENS      = 1024
TEMPERATURE     = 0.2
N_RUNS          = int(os.environ.get("N_RUNS", "3"))  # Set via: bash scripts/benchmark.sh [n_runs]

# Rigorous prompt that exercises code generation depth
SYSTEM_MSG = (
    "You are an expert systems programmer. Provide complete, production-ready code "
    "with no placeholders, full error handling, and inline comments explaining "
    "non-obvious design decisions."
)

PROMPT = (
    "Design and implement a high-performance asynchronous TCP server in Rust using Tokio. "
    "The server must:\n"
    "1. Accept concurrent connections using tokio::net::TcpListener with a configurable "
    "   backlog and bind address.\n"
    "2. Implement a custom binary framing protocol: 4-byte little-endian length prefix "
    "   followed by a MessagePack-encoded payload.\n"
    "3. Use a Tokio broadcast channel to fan-out incoming messages to all connected clients "
    "   (pub-sub pattern).\n"
    "4. Implement graceful shutdown via tokio::signal::ctrl_c(), draining in-flight "
    "   connections with a configurable timeout.\n"
    "5. Track active connection count with std::sync::atomic::AtomicUsize and expose it "
    "   via a /metrics endpoint using axum.\n"
    "Provide full Cargo.toml dependencies and the complete main.rs source."
)

def run_inference(run_num: int) -> dict:
    payload = {
        "model": None,           # Server selects the loaded model
        "messages": [
            {"role": "system",  "content": SYSTEM_MSG},
            {"role": "user",    "content": PROMPT},
        ],
        "max_tokens":  MAX_TOKENS,
        "temperature": TEMPERATURE,
        "stream":      False,
    }

    # Discover the loaded model name from /v1/models
    try:
        models_req = urllib.request.urlopen("http://localhost:8000/v1/models", timeout=10)
        models_data = json.loads(models_req.read().decode())
        payload["model"] = models_data["data"][0]["id"]
    except Exception as e:
        print(f"  [WARN] Could not fetch model name: {e}. Using wildcard.")
        payload["model"] = "default"

    body = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={
            "Content-Type":  "application/json",
            "Authorization": "Bearer dummy",
        },
        method="POST",
    )

    print(f"  Run {run_num}/{N_RUNS}: sending request...", flush=True)
    t_start = time.perf_counter()

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            raw    = resp.read().decode("utf-8")
            t_end  = time.perf_counter()
            data   = json.loads(raw)
    except urllib.error.HTTPError as e:
        body_err = e.read().decode("utf-8", errors="replace")
        print(f"\n  [ERROR] HTTP {e.code}: {body_err}", file=sys.stderr)
        sys.exit(1)

    elapsed    = t_end - t_start
    usage      = data.get("usage", {})
    prompt_tok = usage.get("prompt_tokens",     0)
    comp_tok   = usage.get("completion_tokens", 0)
    total_tok  = usage.get("total_tokens",      0)
    throughput = comp_tok / elapsed if elapsed > 0 else 0

    return {
        "run":         run_num,
        "elapsed_s":   round(elapsed,    2),
        "prompt_tok":  prompt_tok,
        "comp_tok":    comp_tok,
        "total_tok":   total_tok,
        "tok_per_s":   round(throughput, 2),
        "finish":      data.get("choices", [{}])[0].get("finish_reason", "unknown"),
        "model":       payload["model"],
    }

# ---------------------------------------------------------------------------
# Execute N_RUNS and collect metrics
# ---------------------------------------------------------------------------
results = []
for i in range(1, N_RUNS + 1):
    try:
        r = run_inference(i)
        results.append(r)
        print(f"    ✓ Run {r['run']}: {r['comp_tok']} tokens in {r['elapsed_s']}s → {r['tok_per_s']} tok/s")
    except SystemExit:
        raise
    except Exception as e:
        print(f"  [WARN] Run {i} failed: {e}", file=sys.stderr)

if not results:
    print("[FAIL] All benchmark runs failed.", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Aggregate statistics
# ---------------------------------------------------------------------------
avg_elapsed  = sum(r["elapsed_s"]  for r in results) / len(results)
avg_comp_tok = sum(r["comp_tok"]   for r in results) / len(results)
avg_tok_s    = sum(r["tok_per_s"]  for r in results) / len(results)
min_tok_s    = min(r["tok_per_s"]  for r in results)
max_tok_s    = max(r["tok_per_s"]  for r in results)
avg_prompt   = sum(r["prompt_tok"] for r in results) / len(results)

SEP   = "─" * 64
DSEP  = "═" * 64

print(f"\n\033[1m{DSEP}\033[0m")
print(f"\033[1m  BENCHMARK RESULTS — vLLM Local Inference\033[0m")
print(f"\033[1m{DSEP}\033[0m")

# Per-run table
print(f"\n  {'Run':<6} {'Elapsed (s)':<14} {'Prompt tok':<14} {'Comp tok':<12} {'Tok/s':<10} {'Finish'}")
print(f"  {SEP}")
for r in results:
    print(f"  {r['run']:<6} {r['elapsed_s']:<14.2f} {r['prompt_tok']:<14} {r['comp_tok']:<12} {r['tok_per_s']:<10.2f} {r['finish']}")

# Aggregate summary
print(f"\n  {DSEP}")
print(f"  \033[1mSUMMARY (n={len(results)} runs)\033[0m")
print(f"  {DSEP}")
print(f"  {'Metric':<35} {'Value'}")
print(f"  {SEP}")
print(f"  {'Avg prompt tokens':<35} {avg_prompt:.0f}")
print(f"  {'Avg completion tokens':<35} {avg_comp_tok:.0f}")
print(f"  {'Avg generation time':<35} {avg_elapsed:.2f} s")
print(f"  {'Avg throughput':<35} {avg_tok_s:.2f} tok/s")
print(f"  {'Peak throughput':<35} {max_tok_s:.2f} tok/s")
print(f"  {'Min throughput':<35} {min_tok_s:.2f} tok/s")
print(f"  {'Max tokens requested':<35} {MAX_TOKENS}")
print(f"  {'Temperature':<35} {TEMPERATURE}")
print(f"  \033[1m{DSEP}\033[0m")

# Performance tier classification
if avg_tok_s >= 30:
    tier, tier_label = "\033[32m🚀 Excellent (≥30 tok/s)\033[0m", "excellent"
elif avg_tok_s >= 15:
    tier, tier_label = "\033[33m✓ Good (15–30 tok/s)\033[0m", "good"
elif avg_tok_s >= 5:
    tier, tier_label = "\033[33m⚠ Moderate (5–15 tok/s)\033[0m", "moderate"
else:
    tier, tier_label = "\033[31m✗ Low (<5 tok/s — check VRAM utilization and PCIe)\033[0m", "low"

print(f"\n  Performance tier: {tier}\n")

# ---------------------------------------------------------------------------
# Persist for historical comparison (see scripts/compare-benchmarks.sh)
# ---------------------------------------------------------------------------
record = {
    "type":                "benchmark",
    "timestamp_utc":       time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "model":               results[0]["model"],
    "n_runs":               len(results),
    "max_tokens":          MAX_TOKENS,
    "temperature":         TEMPERATURE,
    "avg_prompt_tokens":   round(avg_prompt, 0),
    "avg_completion_tokens": round(avg_comp_tok, 0),
    "avg_elapsed_s":       round(avg_elapsed, 2),
    "avg_tok_per_s":       round(avg_tok_s, 2),
    "peak_tok_per_s":      round(max_tok_s, 2),
    "min_tok_per_s":       round(min_tok_s, 2),
    "performance_tier":    tier_label,
    "runs":                results,
}
result_file = os.environ.get("RESULT_FILE")
if result_file:
    with open(result_file, "w") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print(f"  Results saved to: {result_file}\n")
PYEOF

# =============================================================================
# STEP 3 — Post-benchmark GPU state snapshot
# =============================================================================
step "STEP 3/3 — Post-Benchmark GPU State"

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
echo ""
printf "  %-6s %-35s %-12s %-12s %-10s %-10s\n" \
  "GPU" "Name" "Temp (°C)" "Power (W)" "Used MiB" "Free MiB"
printf "  %s\n" "$(printf '─%.0s' {1..90})"

for i in $(seq 0 $((GPU_COUNT - 1))); do
  NAME=$(nvidia-smi -i "$i" --query-gpu=name           --format=csv,noheader | xargs)
  TEMP=$(nvidia-smi -i "$i" --query-gpu=temperature.gpu --format=csv,noheader,nounits | xargs)
  POWR=$(nvidia-smi -i "$i" --query-gpu=power.draw      --format=csv,noheader,nounits | xargs)
  USED=$(nvidia-smi -i "$i" --query-gpu=memory.used     --format=csv,noheader,nounits | xargs)
  FREE=$(nvidia-smi -i "$i" --query-gpu=memory.free     --format=csv,noheader,nounits | xargs)
  printf "  %-6s %-35s %-12s %-12s %-10s %-10s\n" \
    "$i" "${NAME:0:35}" "${TEMP}" "${POWR}" "${USED}" "${FREE}"
done

echo ""
ok "Benchmark complete."
