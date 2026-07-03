#!/usr/bin/env bash
# =============================================================================
# compare-benchmarks.sh
# Regression detector for benchmark.sh / load-test.sh history.
#
# benchmark.sh and load-test.sh each write a timestamped JSON record into
# benchmark-results/ on every run. This script diffs two of those records
# (same type — benchmark vs benchmark, or load_test vs load_test) and flags
# whether a change to deploy/.env (via tune-inference.sh) or host tuning
# (via check-bottlenecks.sh's recommendations) made things better or worse.
#
# Usage:
#   bash scripts/compare-benchmarks.sh                       # latest 2 benchmark runs
#   bash scripts/compare-benchmarks.sh --load-test            # latest 2 load-test runs
#   bash scripts/compare-benchmarks.sh <file_a.json> <file_b.json>   # explicit pair
#   bash scripts/compare-benchmarks.sh --prune [--keep N]     # dry run: list what a prune would delete (default N=20)
#   bash scripts/compare-benchmarks.sh --prune [--keep N] --force   # actually delete
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/benchmark-results"

if [[ ! -d "${RESULTS_DIR}" ]]; then
  fail "${RESULTS_DIR} does not exist yet. Run bash scripts/benchmark.sh or bash scripts/load-test.sh at least twice first."
fi

# =============================================================================
# --prune mode: keep the N most recent files per type, list/delete the rest.
# Defaults to a dry run (list only) — deleting benchmark history is a
# destructive, irreversible action, so it requires an explicit --force.
# =============================================================================
if [[ "${1:-}" == "--prune" ]]; then
  shift
  KEEP=20
  FORCE=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep)
        KEEP="${2:-}"
        [[ "${KEEP}" =~ ^[0-9]+$ ]] || fail "Invalid --keep value '${KEEP}'. Must be a non-negative integer."
        shift 2
        ;;
      --force)
        FORCE=true
        shift
        ;;
      *)
        fail "Unknown --prune argument '$1'. Usage: bash scripts/compare-benchmarks.sh --prune [--keep N] [--force]"
        ;;
    esac
  done

  step "Pruning benchmark-results/ (keep last ${KEEP} per type, mode: $([[ "${FORCE}" == "true" ]] && echo DELETE || echo "DRY RUN"))"

  TOTAL_CANDIDATES=0
  for PAIR in "benchmark_*.json:benchmark" "loadtest_*.json:load_test"; do
    P_PATTERN="${PAIR%%:*}"
    P_KIND="${PAIR##*:}"
    mapfile -t P_MATCHES < <(find "${RESULTS_DIR}" -maxdepth 1 -name "${P_PATTERN}" -type f | sort)
    P_COUNT=${#P_MATCHES[@]}

    if [[ "${P_COUNT}" -le "${KEEP}" ]]; then
      info "${P_KIND}: ${P_COUNT} file(s), at or under the keep limit (${KEEP}) — nothing to prune."
      continue
    fi

    P_DELETE_COUNT=$(( P_COUNT - KEEP ))
    info "${P_KIND}: ${P_COUNT} file(s) found, keeping the ${KEEP} most recent, ${P_DELETE_COUNT} candidate(s) for removal:"
    for ((idx=0; idx<P_DELETE_COUNT; idx++)); do
      echo "    - $(basename "${P_MATCHES[$idx]}")"
      TOTAL_CANDIDATES=$(( TOTAL_CANDIDATES + 1 ))
      if [[ "${FORCE}" == "true" ]]; then
        rm -f "${P_MATCHES[$idx]}"
      fi
    done
  done

  echo ""
  if [[ "${TOTAL_CANDIDATES}" -eq 0 ]]; then
    ok "Nothing to prune."
  elif [[ "${FORCE}" == "true" ]]; then
    ok "Deleted ${TOTAL_CANDIDATES} file(s)."
  else
    warn "Dry run — ${TOTAL_CANDIDATES} file(s) would be deleted. Re-run with --force to actually delete them."
  fi
  exit 0
fi

# =============================================================================
# STEP 1 — Resolve which two files to compare
# =============================================================================
step "STEP 1/2 — Resolving Comparison Pair"

PATTERN="benchmark_*.json"
KIND="benchmark"

if [[ "${1:-}" == "--load-test" ]]; then
  PATTERN="loadtest_*.json"
  KIND="load_test"
  shift
elif [[ "${1:-}" == --* ]]; then
  fail "Unknown argument '${1}'. Usage: bash scripts/compare-benchmarks.sh [--load-test] [file_a.json file_b.json] | --prune [--keep N] [--force]"
fi

if [[ $# -ge 2 ]]; then
  FILE_A="$1"
  FILE_B="$2"
  [[ -f "${FILE_A}" ]] || fail "File not found: ${FILE_A}"
  [[ -f "${FILE_B}" ]] || fail "File not found: ${FILE_B}"
  info "Comparing explicit files:"
else
  # Most recent two files matching PATTERN, sorted by filename (timestamp-prefixed → lexical == chronological)
  mapfile -t MATCHES < <(find "${RESULTS_DIR}" -maxdepth 1 -name "${PATTERN}" -type f | sort)
  if [[ ${#MATCHES[@]} -lt 2 ]]; then
    fail "Need at least 2 '${PATTERN}' files in ${RESULTS_DIR} to compare (found ${#MATCHES[@]}). Run the ${KIND} script again after a tuning change."
  fi
  FILE_B="${MATCHES[-1]}"   # newest
  FILE_A="${MATCHES[-2]}"   # previous
  info "Auto-selected the two most recent ${KIND} runs:"
fi

echo "    Baseline (older) : $(basename "${FILE_A}")"
echo "    Candidate (newer): $(basename "${FILE_B}")"

# =============================================================================
# STEP 2 — Diff and classify
# =============================================================================
step "STEP 2/2 — Comparing Results"

set +e
FILE_A="${FILE_A}" FILE_B="${FILE_B}" python3 - <<'PYEOF'
import json
import os
import sys

file_a = os.environ["FILE_A"]
file_b = os.environ["FILE_B"]

def load_record(path):
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"[FAIL] {path} is not valid JSON ({e}). It may be truncated or corrupted — check disk space at the time it was written, or delete it and re-run the script that generated it.", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"[FAIL] Could not read {path}: {e}", file=sys.stderr)
        sys.exit(2)

a = load_record(file_a)
b = load_record(file_b)

if a.get("type") != b.get("type"):
    print(f"[FAIL] Type mismatch: {file_a} is '{a.get('type')}', {file_b} is '{b.get('type')}'. Compare same-type files only.", file=sys.stderr)
    sys.exit(2)

kind = a["type"]

# (label, key, "higher_is_better", regression_threshold_pct)
if kind == "benchmark":
    metrics = [
        ("Avg throughput (tok/s)", "avg_tok_per_s", True, 10),
        ("Peak throughput (tok/s)", "peak_tok_per_s", True, 10),
        ("Avg generation time (s)", "avg_elapsed_s", False, 15),
    ]
else:
    metrics = [
        ("Requests/sec", "requests_per_s", True, 10),
        ("Aggregate completion tok/s", "aggregate_completion_tok_s", True, 10),
        ("p50 latency (s)", "latency_p50_s", False, 15),
        ("p95 latency (s)", "latency_p95_s", False, 15),
        ("p99 latency (s)", "latency_p99_s", False, 20),
    ]

SEP = "─" * 78
print(f"\n  Model (baseline) : {a.get('model', 'unknown')}")
print(f"  Model (candidate): {b.get('model', 'unknown')}")
if a.get("model") != b.get("model"):
    print("  \033[33m[WARN] Comparing runs against two different models — deltas below may reflect the model change, not tuning.\033[0m")

print(f"\n  {'Metric':<30} {'Baseline':<14} {'Candidate':<14} {'Delta':<12} {'Status'}")
print(f"  {SEP}")

any_regression = False
for label, key, higher_is_better, threshold_pct in metrics:
    va = a.get(key)
    vb = b.get(key)
    if va is None or vb is None:
        print(f"  {label:<30} {'n/a':<14} {'n/a':<14} {'':<12} skipped")
        continue

    delta_pct = ((vb - va) / va * 100) if va != 0 else 0.0
    improved = delta_pct > 0 if higher_is_better else delta_pct < 0
    regressed = (-delta_pct if higher_is_better else delta_pct) >= threshold_pct

    if regressed:
        status = "\033[31m✗ REGRESSION\033[0m"
        any_regression = True
    elif improved and abs(delta_pct) >= threshold_pct:
        status = "\033[32m✓ IMPROVED\033[0m"
    else:
        status = "stable"

    sign = "+" if delta_pct >= 0 else ""
    print(f"  {label:<30} {va:<14} {vb:<14} {sign}{delta_pct:.1f}%{'':<6} {status}")

print(f"  {SEP}\n")

if any_regression:
    print("\033[31m\033[1m  ✗ Regression detected — candidate run is meaningfully worse on at least one metric.\033[0m")
    print("  Review recent changes to deploy/.env (tune-inference.sh) or host state (check-bottlenecks.sh).")
    sys.exit(1)
else:
    print("\033[32m\033[1m  ✓ No regression — candidate run is stable or improved relative to baseline.\033[0m")
    sys.exit(0)
PYEOF
STATUS=$?
set -e

if [[ ${STATUS} -eq 2 ]]; then
  fail "Comparison could not run — see error above."
elif [[ ${STATUS} -eq 1 ]]; then
  warn "Comparison flagged a regression (see table above). Non-fatal — this script does not modify anything."
  exit 1
else
  ok "Comparison complete. No regression detected."
fi
