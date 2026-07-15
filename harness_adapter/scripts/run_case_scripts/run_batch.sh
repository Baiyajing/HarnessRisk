#!/usr/bin/env bash
# Unified, provider-agnostic batch runner for the controlled mock benchmark.
#
# Iterates the case JSON files in a data dir, runs each one through run_case.sh
# for the chosen harness, records a manifest, and evaluates the batch.
#
# Works for all three harnesses and any provider/model. Optional sequential
# rate pacing (originally gemini-specific) is available for any harness via
# --rate-limit-per-minute.
#
# Replaces: run_gemini_batch.sh, run_microsoft_foundry_batch.sh,
#   run_claude_opus_4_7_batch.sh, run_aiwave_gpt_5_5_batch.sh,
#   run_volcengine_agent_plan_batch.sh, run_hermes_batch.sh,
#   run_hermes_batch_multiturn.sh, run_nanobot_batch.sh,
#   run_nanobot_batch_multiturn.sh
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HARNESS=""
MULTITURN=0
# Case data is distributed separately (see data/README.md). Point at it with
# --data-dir, the positional DATA_DIR, or LIFECYCLE_BENCH_DATA_DIR. Default
# assumes cases were downloaded into <repo>/data.
DATA_DIR="${LIFECYCLE_BENCH_DATA_DIR:-$ADAPTER_DIR/../data}"
RUN_ROOT=""
BATCH_ID=""
BATCH_ID_PREFIX=""
CASE_GLOB="${BATCH_CASE_GLOB:-*.json}"
CASES="${BATCH_CASES:-}"
RATE_LIMIT_PER_MINUTE=0
RATE_WINDOW_SECONDS=60
RATE_MATCH=""            # substring matched against provider/model to count calls
CASE_ARGS=()             # forwarded to run_case.sh (and on to the adapter)

usage() {
  cat <<EOF
Usage:
  $0 --harness <openclaw|hermes|nanobot> [options] [DATA_DIR] [-- run_case.sh args...]

Required:
  --harness NAME             openclaw, hermes, or nanobot.

Options:
  --multiturn                Use multi-turn replay (hermes/nanobot).
  --data-dir DIR             Case data dir. Positional DATA_DIR also accepted.
                             Default: $DATA_DIR
  --run-root DIR             Batch run root. Default per harness:
                             openclaw -> runs/openclaw_adapter
                             hermes   -> runs/hermes_adapter
                             nanobot  -> runs/nanobot_adapter
  --batch-id ID              Full batch directory name (overrides prefix).
  --batch-id-prefix P        Prefix for the auto-timestamped batch id.
                             Default: batch-<harness>[-multiturn]
  --case-glob GLOB           Case file glob. Default: $CASE_GLOB
  --cases "id1 id2"          Restrict to these case ids (comma/space separated).
  --rate-limit-per-minute N  Enable sequential rate pacing at N calls/window.
                             0 (default) disables pacing.
  --rate-window-seconds N    Rate window length. Default: $RATE_WINDOW_SECONDS
  --rate-match STR           Count only assistant messages whose provider/model
                             contains STR (case-insensitive). Empty = count all
                             assistant API messages.
  -h, --help                 Show this help.

Everything after -- is passed to run_case.sh, e.g. --state-dir, --model,
--provider, --api-key-env, --cmd, --timeout-seconds.

Examples:
  # OpenClaw batch, provider set up via setup_agent.sh:
  $0 --harness openclaw /path/to/data -- \\
    --state-dir "$ADAPTER_DIR/.openclaw-adapter/openclaw-myprovider-state" \\
    --model myprovider/mymodel

  # Hermes multi-turn batch:
  $0 --harness hermes --multiturn /path/to/data -- --model deepseek-v4-pro

  # Gemini-style pacing (1 call/min), any harness:
  $0 --harness openclaw --rate-limit-per-minute 1 --rate-match gemini /path/to/data \\
    -- --model google/gemini-3.1-flash-lite
EOF
}

die() { echo "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:?}"; shift ;;
    --multiturn) MULTITURN=1 ;;
    --data-dir) DATA_DIR="${2:?}"; shift ;;
    --run-root) RUN_ROOT="${2:?}"; shift ;;
    --batch-id) BATCH_ID="${2:?}"; shift ;;
    --batch-id-prefix) BATCH_ID_PREFIX="${2:?}"; shift ;;
    --case-glob) CASE_GLOB="${2:?}"; shift ;;
    --cases) CASES="${2:?}"; shift ;;
    --rate-limit-per-minute) RATE_LIMIT_PER_MINUTE="${2:?}"; shift ;;
    --rate-window-seconds) RATE_WINDOW_SECONDS="${2:?}"; shift ;;
    --rate-match) RATE_MATCH="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; CASE_ARGS+=("$@"); break ;;
    -*) die "Unknown option: $1 (use --help)" ;;
    *) DATA_DIR="$1" ;;
  esac
  shift
done

[[ -n "$HARNESS" ]] || { usage >&2; die "Missing --harness."; }
[[ -d "$DATA_DIR" ]] || die "Data directory does not exist: $DATA_DIR"

case "$HARNESS" in
  openclaw) RUN_ROOT="${RUN_ROOT:-$ADAPTER_DIR/runs/openclaw_adapter}" ;;
  hermes)   RUN_ROOT="${RUN_ROOT:-$ADAPTER_DIR/runs/hermes_adapter}" ;;
  nanobot)  RUN_ROOT="${RUN_ROOT:-$ADAPTER_DIR/runs/nanobot_adapter}" ;;
  *) die "Unknown harness: $HARNESS" ;;
esac

if [[ -z "$BATCH_ID_PREFIX" ]]; then
  BATCH_ID_PREFIX="batch-$HARNESS"
  [[ "$MULTITURN" -eq 1 ]] && BATCH_ID_PREFIX="$BATCH_ID_PREFIX-multiturn"
fi
BATCH_ID="${BATCH_ID:-$BATCH_ID_PREFIX-$(date -u +%Y%m%dT%H%M%SZ)}"

BATCH_RUN_ROOT="$RUN_ROOT/$BATCH_ID"
MANIFEST_PATH="$BATCH_RUN_ROOT/batch_manifest.jsonl"
LOG_PATH="$BATCH_RUN_ROOT/batch.log"
SUMMARY_PATH="$BATCH_RUN_ROOT/evaluation_summary.json"
EVALUATOR_STDOUT_PATH="$BATCH_RUN_ROOT/evaluation_stdout.json"

mkdir -p "$BATCH_RUN_ROOT"
: > "$MANIFEST_PATH"
: > "$LOG_PATH"

case_filter=" ${CASES//,/ } "
is_case_selected() {
  [[ -z "$CASES" ]] && return 0
  [[ " $case_filter " == *" $1 "* ]]
}

# Accept a case file only if it is a single-case benchmark JSON, and echo its id.
case_id_from_file() {
  python3 - "$1" <<'PY'
import json, re, sys
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
case_id = data.get("case_id")
if isinstance(case_id, str) and re.match(r"^(setup|skill|daily|memory|action|recovery)_\d{3}$", case_id):
    print(case_id)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# Count assistant API messages in a run's transcript, optionally filtered by a
# provider/model substring (case-insensitive). Provider-agnostic.
assistant_call_count() {
  local transcript="$1/trajectory/transcripts.jsonl"
  [[ -f "$transcript" ]] || { echo 0; return; }
  RATE_MATCH="$RATE_MATCH" python3 - "$transcript" <<'PY'
import json, os, sys
match = os.environ.get("RATE_MATCH", "").lower()
count = 0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        try:
            row = json.loads(line)
        except Exception:
            continue
        message = (row.get("entry") or {}).get("message")
        if not isinstance(message, dict):
            continue
        if message.get("role") not in (None, "assistant"):
            continue
        if match:
            hay = (str(message.get("provider") or "") + " " + str(message.get("model") or "")).lower()
            if match not in hay:
                continue
        count += 1
print(count)
PY
}

next_case_epoch=0
wait_for_rate_limit() {
  [[ "$RATE_LIMIT_PER_MINUTE" -le 0 ]] && return
  local now wait_seconds
  now="$(date +%s)"
  if (( next_case_epoch > now )); then
    wait_seconds=$((next_case_epoch - now))
    echo "Rate pacing: sleeping ${wait_seconds}s before next case" | tee -a "$LOG_PATH"
    sleep "$wait_seconds"
  fi
}
update_rate_limit_budget() {
  [[ "$RATE_LIMIT_PER_MINUTE" -le 0 ]] && return
  local run_dir="$1" start_epoch="$2" call_count required_seconds candidate_epoch
  call_count="$(assistant_call_count "$run_dir")"
  required_seconds=$(((call_count * RATE_WINDOW_SECONDS + RATE_LIMIT_PER_MINUTE - 1) / RATE_LIMIT_PER_MINUTE))
  candidate_epoch=$((start_epoch + required_seconds))
  (( candidate_epoch > next_case_epoch )) && next_case_epoch="$candidate_epoch"
  echo "API calls observed: $call_count; reserved window: ${required_seconds}s" | tee -a "$LOG_PATH"
}

CASE_SCRIPT="$ADAPTER_DIR/scripts/run_case_scripts/run_case.sh"
case_cmd=("$CASE_SCRIPT" --harness "$HARNESS")
[[ "$MULTITURN" -eq 1 ]] && case_cmd+=(--multiturn)

echo "Harness: $HARNESS" | tee -a "$LOG_PATH"
echo "Batch id: $BATCH_ID" | tee -a "$LOG_PATH"
echo "Data dir: $DATA_DIR" | tee -a "$LOG_PATH"
echo "Run root: $BATCH_RUN_ROOT" | tee -a "$LOG_PATH"
if [[ "$RATE_LIMIT_PER_MINUTE" -gt 0 ]]; then
  echo "Rate pacing: $RATE_LIMIT_PER_MINUTE calls per ${RATE_WINDOW_SECONDS}s (match='${RATE_MATCH:-*}')" | tee -a "$LOG_PATH"
fi

total=0
completed=0
failed=0

while IFS= read -r case_file; do
  if ! case_id="$(case_id_from_file "$case_file")"; then
    continue
  fi
  if ! is_case_selected "$case_id"; then
    continue
  fi

  wait_for_rate_limit

  total=$((total + 1))
  run_id="${BATCH_ID}-${case_id}"
  run_dir="$BATCH_RUN_ROOT/$run_id"

  echo "" | tee -a "$LOG_PATH"
  echo "[$total] Running $case_id -> $run_dir" | tee -a "$LOG_PATH"

  start_epoch="$(date +%s)"
  set +e
  output="$("${case_cmd[@]}" \
    "${CASE_ARGS[@]}" \
    --data-dir "$DATA_DIR" \
    --run-root "$BATCH_RUN_ROOT" \
    --run-id "$run_id" \
    --case-id "$case_id" 2>&1)"
  rc=$?
  set -e

  echo "$output" | tee -a "$LOG_PATH"
  update_rate_limit_budget "$run_dir" "$start_epoch"

  status="failed"
  if [[ -f "$run_dir/trajectory/trajectory.json" ]]; then
    status="$(python3 - "$run_dir/trajectory/trajectory.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", "unknown"))
except Exception:
    print("unknown")
PY
)"
  fi

  if [[ "$rc" -eq 0 && "$status" == "completed" ]]; then
    completed=$((completed + 1))
  else
    failed=$((failed + 1))
  fi

  calls="$(assistant_call_count "$run_dir")"
  python3 - "$MANIFEST_PATH" "$case_id" "$run_id" "$run_dir" "$status" "$rc" "$calls" <<'PY'
import json, sys
manifest, case_id, run_id, run_dir, status, rc, calls = sys.argv[1:]
row = {
    "case_id": case_id,
    "run_id": run_id,
    "run_dir": run_dir,
    "status": status,
    "exit_code": int(rc),
    "assistant_api_calls": int(calls),
}
with open(manifest, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
PY
done < <(find "$DATA_DIR" -maxdepth 1 -type f -name "$CASE_GLOB" | sort)

echo "" | tee -a "$LOG_PATH"
echo "Finished batch: total=$total completed=$completed failed=$failed" | tee -a "$LOG_PATH"

if [[ "$total" -eq 0 ]]; then
  echo "No case JSON files were selected from $DATA_DIR" | tee -a "$LOG_PATH"
  exit 2
fi

echo "Evaluating runs..." | tee -a "$LOG_PATH"
python3 "$ADAPTER_DIR/scripts/evaluate_run.py" \
  --run-root "$BATCH_RUN_ROOT" \
  --data-dir "$DATA_DIR" \
  --completed-only \
  --output "$SUMMARY_PATH" \
  --pretty > "$EVALUATOR_STDOUT_PATH"

python3 - "$SUMMARY_PATH" "$BATCH_ID" "$DATA_DIR" "$BATCH_RUN_ROOT" "$MANIFEST_PATH" "$total" "$completed" "$failed" "$HARNESS" <<'PY'
import json, sys
METRIC_KEYS = ["utility_score", "attack_success_rate", "persistence_score", "detection_score"]

def aggregate(runs):
    scored = [run for run in runs if isinstance(run.get("metrics"), dict)]
    out = {"count": len(scored)}
    for key in METRIC_KEYS:
        values = [float(run["metrics"].get(key, 0.0)) for run in scored]
        out[key] = round(sum(values) / len(values), 4) if values else 0.0
    return out

(summary_path, batch_id, data_dir, batch_run_root, manifest_path,
 total, completed, failed, harness) = sys.argv[1:]
with open(summary_path, encoding="utf-8") as fh:
    payload = json.load(fh)
payload["summary_completed_only"] = payload.get("summary", {})
payload["summary_all_evaluated_runs"] = aggregate(payload.get("runs", []))
payload["batch"] = {
    "batch_id": batch_id,
    "harness": harness,
    "data_dir": data_dir,
    "run_root": batch_run_root,
    "manifest": manifest_path,
    "total_cases": int(total),
    "completed_cases": int(completed),
    "failed_cases": int(failed),
}
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

cat "$SUMMARY_PATH" | tee -a "$LOG_PATH"

echo "" | tee -a "$LOG_PATH"
echo "Batch artifacts:" | tee -a "$LOG_PATH"
echo "  Run root: $BATCH_RUN_ROOT" | tee -a "$LOG_PATH"
echo "  Manifest: $MANIFEST_PATH" | tee -a "$LOG_PATH"
echo "  Evaluation summary: $SUMMARY_PATH" | tee -a "$LOG_PATH"
echo "  Log: $LOG_PATH" | tee -a "$LOG_PATH"
