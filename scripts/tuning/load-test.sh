#!/usr/bin/env bash
# =============================================================================
# load-test.sh
# Concurrent request load tester for the local vLLM inference server.
#
# benchmark.sh measures single-stream sequential throughput (one request at a
# time, large completion). That answers "how fast is one generation?" but not
# "how does the server behave when multiple clients hit it at once?" — which
# is the shape of real usage (multiple editor sessions, multiple users).
# This script answers the second question: fixed concurrency, many small
# requests, aggregate throughput + latency percentiles (p50/p95/p99).
#
# Usage: bash scripts/load-test.sh [concurrency] [duration_seconds]
#   concurrency       Number of simultaneous in-flight requests (default: 4)
#   duration_seconds  How long each worker keeps firing requests (default: 30)
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

# --- CLI args ------------------------------------------------------------
CONCURRENCY="${1:-4}"
DURATION_S="${2:-30}"

if ! [[ "${CONCURRENCY}" =~ ^[0-9]+$ ]] || [[ "${CONCURRENCY}" -lt 1 ]]; then
  fail "Invalid concurrency '${CONCURRENCY}'. Usage: bash scripts/load-test.sh [concurrency] [duration_seconds]"
fi
if ! [[ "${DURATION_S}" =~ ^[0-9]+$ ]] || [[ "${DURATION_S}" -lt 1 ]]; then
  fail "Invalid duration_seconds '${DURATION_S}'. Usage: bash scripts/load-test.sh [concurrency] [duration_seconds]"
fi

# --- Repo-relative results dir (historical tracking, same pattern as benchmark.sh) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/benchmark-results"
mkdir -p "${RESULTS_DIR}"
RESULT_FILE="${RESULTS_DIR}/loadtest_$(date -u '+%Y%m%dT%H%M%SZ').json"

export CONCURRENCY DURATION_S RESULT_FILE

# =============================================================================
# STEP 1 — Verify endpoint availability
# =============================================================================
step "STEP 1/2 — Endpoint Availability Check"

info "Usage: bash scripts/load-test.sh [concurrency] [duration_seconds]"
info "Running with concurrency=${CONCURRENCY}, duration=${DURATION_S}s"

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
# STEP 2 — Concurrent load test
# =============================================================================
step "STEP 2/2 — Load Test (concurrency=${CONCURRENCY}, duration=${DURATION_S}s)"

info "Each of ${CONCURRENCY} workers fires short completions back-to-back for ${DURATION_S}s."
info "This measures aggregate server throughput under concurrent load, not"
info "single-stream generation speed (see benchmark.sh for that)."
echo ""

# --- Sustained-load GPU throttle/thermal sampler -----------------------------
# check-bottlenecks.sh catches a *misconfigured* power cap (setting below
# board max) before the fact. This catches *actual* throttling as it happens
# under real sustained concurrent load — a card can be at its full power cap
# and still throttle from heat once it's been under load for tens of seconds,
# which a point-in-time check can't see.
THROTTLE_LOG=""
THROTTLE_SAMPLER_PID=""
if command -v nvidia-smi &>/dev/null; then
  THROTTLE_LOG="$(mktemp)"
  (
    END_TS=$(( $(date +%s) + DURATION_S + 3 ))
    while [ "$(date +%s)" -lt "${END_TS}" ]; do
      TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      nvidia-smi --query-gpu=index,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | awk -v ts="${TS}" '{print ts","$0}' >> "${THROTTLE_LOG}"
      sleep 1
    done
  ) &
  THROTTLE_SAMPLER_PID=$!
else
  warn "nvidia-smi not found — skipping GPU throttle sampling during this run."
fi
export THROTTLE_LOG

set +e
python3 - <<'PYEOF'
import concurrent.futures
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

ENDPOINT     = "http://localhost:8000/v1/chat/completions"
MODELS_URL   = "http://localhost:8000/v1/models"
CONCURRENCY  = int(os.environ["CONCURRENCY"])
DURATION_S   = int(os.environ["DURATION_S"])
RESULT_FILE  = os.environ["RESULT_FILE"]
MAX_TOKENS   = 128     # Small completions: more samples per second, closer to
                        # interactive autocomplete/chat turn-around than a
                        # single giant generation.
TEMPERATURE  = 0.2

PROMPT = (
    "Write a Python function that returns the nth Fibonacci number using "
    "memoization. Include a docstring."
)

# Discover the live served model name (same pattern as benchmark.sh /
# setup-continue.sh — never hard-code it, `served-model-name` can change).
try:
    r = urllib.request.urlopen(MODELS_URL, timeout=10)
    MODEL_ID = json.loads(r.read().decode())["data"][0]["id"]
except Exception as e:
    print(f"  [WARN] Could not fetch model name: {e}. Using 'default'.")
    MODEL_ID = "default"

stop_at = time.perf_counter() + DURATION_S
lock = __import__("threading").Lock()
results = []
errors = []

def worker(worker_id: int):
    local_count = 0
    while time.perf_counter() < stop_at:
        payload = {
            "model": MODEL_ID,
            "messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "stream": False,
        }
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            ENDPOINT,
            data=body,
            headers={"Content-Type": "application/json", "Authorization": "Bearer dummy"},
            method="POST",
        )
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read().decode("utf-8")
            elapsed = time.perf_counter() - t0
            data = json.loads(raw)
            usage = data.get("usage", {})
            with lock:
                results.append({
                    "worker": worker_id,
                    "latency_s": elapsed,
                    "prompt_tokens": usage.get("prompt_tokens", 0),
                    "completion_tokens": usage.get("completion_tokens", 0),
                })
        except Exception as e:
            with lock:
                errors.append(str(e))
        local_count += 1
    return local_count

print(f"  Spawning {CONCURRENCY} concurrent workers for {DURATION_S}s...", flush=True)
wall_start = time.perf_counter()

with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
    futures = [pool.submit(worker, i) for i in range(CONCURRENCY)]
    for f in concurrent.futures.as_completed(futures):
        f.result()

wall_elapsed = time.perf_counter() - wall_start

if not results:
    print("[FAIL] All requests failed under load.", file=sys.stderr)
    for e in errors[:5]:
        print(f"  sample error: {e}", file=sys.stderr)
    sys.exit(1)

latencies = sorted(r["latency_s"] for r in results)
def pct(p):
    idx = min(int(len(latencies) * p) , len(latencies) - 1)
    return latencies[idx]

total_completion_tok = sum(r["completion_tokens"] for r in results)
total_prompt_tok     = sum(r["prompt_tokens"] for r in results)
n_requests            = len(results)
n_errors              = len(errors)
req_per_s             = n_requests / wall_elapsed if wall_elapsed > 0 else 0
aggregate_tok_s        = total_completion_tok / wall_elapsed if wall_elapsed > 0 else 0

SEP  = "─" * 64
DSEP = "═" * 64

print(f"\n\033[1m{DSEP}\033[0m")
print(f"\033[1m  LOAD TEST RESULTS — vLLM Local Inference\033[0m")
print(f"\033[1m{DSEP}\033[0m")
print(f"\n  {'Metric':<35} {'Value'}")
print(f"  {SEP}")
print(f"  {'Concurrency':<35} {CONCURRENCY}")
print(f"  {'Wall-clock duration':<35} {wall_elapsed:.2f} s")
print(f"  {'Completed requests':<35} {n_requests}")
print(f"  {'Failed requests':<35} {n_errors}")
print(f"  {'Requests/sec (aggregate)':<35} {req_per_s:.2f}")
print(f"  {'Completion tokens/sec (aggregate)':<35} {aggregate_tok_s:.2f}")
print(f"  {'Avg prompt tokens/request':<35} {total_prompt_tok / n_requests:.0f}")
print(f"  {'Avg completion tokens/request':<35} {total_completion_tok / n_requests:.0f}")
print(f"\n  {'Latency percentile':<35} {'Value'}")
print(f"  {SEP}")
print(f"  {'p50':<35} {pct(0.50):.2f} s")
print(f"  {'p95':<35} {pct(0.95):.2f} s")
print(f"  {'p99':<35} {pct(0.99):.2f} s")
print(f"  {'max':<35} {latencies[-1]:.2f} s")
print(f"  \033[1m{DSEP}\033[0m")

if n_errors > 0:
    print(f"\n  \033[33mSample errors (showing up to 5 of {n_errors}):\033[0m")
    for e in errors[:5]:
        print(f"    - {e}")

# Persist for historical comparison (see scripts/compare-benchmarks.sh)
record = {
    "type": "load_test",
    "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "model": MODEL_ID,
    "concurrency": CONCURRENCY,
    "duration_s": DURATION_S,
    "wall_elapsed_s": round(wall_elapsed, 2),
    "completed_requests": n_requests,
    "failed_requests": n_errors,
    "requests_per_s": round(req_per_s, 2),
    "aggregate_completion_tok_s": round(aggregate_tok_s, 2),
    "latency_p50_s": round(pct(0.50), 2),
    "latency_p95_s": round(pct(0.95), 2),
    "latency_p99_s": round(pct(0.99), 2),
    "latency_max_s": round(latencies[-1], 2),
}
with open(RESULT_FILE, "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
print(f"\n  Results saved to: {RESULT_FILE}")

if n_errors > 0:
    sys.exit(1)
PYEOF
LOAD_TEST_EXIT=$?
set -e

# Stop the throttle sampler now that the load test has finished.
if [[ -n "${THROTTLE_SAMPLER_PID}" ]]; then
  kill "${THROTTLE_SAMPLER_PID}" 2>/dev/null || true
  wait "${THROTTLE_SAMPLER_PID}" 2>/dev/null || true
fi

if [[ -n "${THROTTLE_LOG}" && -s "${THROTTLE_LOG}" ]]; then
  set +e
  THROTTLE_LOG="${THROTTLE_LOG}" RESULT_FILE="${RESULT_FILE}" python3 - <<'PYEOF'
import json
import os

throttle_log = os.environ["THROTTLE_LOG"]
result_file = os.environ["RESULT_FILE"]

REASON_FIELDS = ["sw_power_cap", "hw_slowdown", "hw_thermal_slowdown", "hw_power_brake_slowdown", "sw_thermal_slowdown"]

events = []
gpu_max_temp = {}
gpu_max_power = {}

with open(throttle_log) as f:
    for line in f:
        parts = [p.strip() for p in line.strip().split(",")]
        if len(parts) < 9:
            continue
        ts, gpu = parts[0], parts[1]
        reason_values = parts[2:7]
        temp, power = parts[7], parts[8]
        try:
            gpu_i = int(gpu)
            temp_f = float(temp)
            power_f = float(power)
        except ValueError:
            continue
        gpu_max_temp[gpu_i] = max(gpu_max_temp.get(gpu_i, 0.0), temp_f)
        gpu_max_power[gpu_i] = max(gpu_max_power.get(gpu_i, 0.0), power_f)
        active = [name for name, val in zip(REASON_FIELDS, reason_values) if val == "Active"]
        if active:
            events.append({"timestamp": ts, "gpu": gpu_i, "reasons": active})

SEP = "─" * 64
print(f"\n\033[1m  GPU Throttle/Thermal Check (sampled every ~1s during the run)\033[0m")
print(f"  {SEP}")
for gpu_i in sorted(gpu_max_temp):
    print(f"  GPU {gpu_i}: peak {gpu_max_temp[gpu_i]:.0f}°C, peak {gpu_max_power[gpu_i]:.1f}W")

if events:
    distinct_reasons = sorted({r for e in events for r in e["reasons"]})
    print(f"\n  \033[33m⚠ Throttling detected during load: {len(events)} sample(s) across reasons: {', '.join(distinct_reasons)}\033[0m")
    print(f"  \033[33mThis is *actual* throttling under sustained load, distinct from check-bottlenecks.sh's\033[0m")
    print(f"  \033[33mpoint-in-time power-cap-setting check. If hw_thermal_slowdown/sw_thermal_slowdown\033[0m")
    print(f"  \033[33mappear, check GPU cooling/airflow; if sw_power_cap, the power limit is being hit\033[0m")
    print(f"  \033[33munder real load even though it wasn't capped below board max at idle.\033[0m")
else:
    print(f"\n  \033[32m✓ No throttling detected during the load test.\033[0m")

# Merge into the JSON record compare-benchmarks.sh / future tooling can read.
try:
    with open(result_file) as f:
        record = json.load(f)
    record["gpu_throttle_events"] = len(events)
    record["gpu_throttle_reasons"] = sorted({r for e in events for r in e["reasons"]})
    record["gpu_max_temp_c"] = gpu_max_temp
    record["gpu_max_power_w"] = gpu_max_power
    with open(result_file, "w") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
except FileNotFoundError:
    pass
PYEOF
  set -e
fi
[[ -n "${THROTTLE_LOG}" ]] && rm -f "${THROTTLE_LOG}"

echo ""
if [[ ${LOAD_TEST_EXIT} -ne 0 ]]; then
  fail "Load test finished with errors (see above)."
fi
ok "Load test complete."
