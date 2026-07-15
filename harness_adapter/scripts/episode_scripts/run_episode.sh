#!/usr/bin/env bash
# Harness-agnostic episode entry point.
#
# Drives one episode (an ordered set of subtasks sharing persistent workspace
# state) through episode_runner.py, using the unified run_case.sh runner. It
# forwards the standard --data-dir/--run-root/--run-id/--case-id contract that
# run_case.sh accepts.
#
# Usage:
#   run_episode.sh --episode PATH --harness HARNESS [options] [-- extra runner args]
#
# Options:
#   --episode PATH        Episode definition JSON (required).
#   --harness NAME        openclaw | hermes | nanobot
#                         Drives run_case_scripts/run_case.sh --harness NAME.
#   --case-runner PATH    Explicit runner path (overrides --harness).
#   --multiturn           Prefer the _multiturn variant of the runner if present.
#   --run-root DIR        Default: runs/episode_adapter
#   --episode-run-id ID   Default: <episode_id>[-<harness>]
#   --carry-mock-services Carry mock-service state across subtasks.
#   --dry-run             Validate carry + metrics offline (no harness/model).
#   -- ...                Everything after -- is forwarded to the case runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"          # .../openclaw_adapter
RUNNER_DIR="$ROOT_DIR/scripts/run_case_scripts"
EPISODE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/episode_runner.py"

EPISODE=""
HARNESS=""
CASE_RUNNER=""
MULTITURN=0
RUN_ROOT="$ROOT_DIR/runs/episode_adapter"
EPISODE_RUN_ID=""
CARRY_MOCK=0
DRY_RUN=0
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --episode) EPISODE="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --case-runner) CASE_RUNNER="$2"; shift 2 ;;
    --multiturn) MULTITURN=1; shift ;;
    --run-root) RUN_ROOT="$2"; shift 2 ;;
    --episode-run-id) EPISODE_RUN_ID="$2"; shift 2 ;;
    --carry-mock-services) CARRY_MOCK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$EPISODE" ]]; then
  echo "--episode is required" >&2; exit 2
fi

# Resolve the case runner. Unless an explicit --case-runner is given, drive the
# unified run_case.sh and inject the harness selection into the forwarded args.
if [[ -z "$CASE_RUNNER" && "$DRY_RUN" -eq 0 ]]; then
  if [[ -z "$HARNESS" ]]; then
    echo "Provide --harness or --case-runner (or use --dry-run)" >&2; exit 2
  fi
  CASE_RUNNER="$RUNNER_DIR/run_case.sh"
  harness_args=(--harness "$HARNESS")
  [[ "$MULTITURN" -eq 1 ]] && harness_args+=(--multiturn)
  # run_case.sh parses --harness/--multiturn regardless of position; the standard
  # --data-dir/--run-id/--case-id contract flows through as adapter passthrough.
  EXTRA=("${harness_args[@]}" ${EXTRA[@]+"${EXTRA[@]}"})
fi

if [[ -z "$EPISODE_RUN_ID" ]]; then
  ep_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["episode_id"])' "$EPISODE")"
  if [[ -n "$HARNESS" ]]; then
    EPISODE_RUN_ID="${ep_id}-${HARNESS}"
  else
    EPISODE_RUN_ID="$ep_id"
  fi
fi

args=(--episode "$EPISODE" --run-root "$RUN_ROOT" --episode-run-id "$EPISODE_RUN_ID")
[[ -n "$CASE_RUNNER" ]] && args+=(--case-runner "$CASE_RUNNER")
[[ "$CARRY_MOCK" -eq 1 ]] && args+=(--carry-mock-services)
[[ "$DRY_RUN" -eq 1 ]] && args+=(--dry-run)

echo "Episode:        $EPISODE"
echo "Harness:        ${HARNESS:-(none)}"
echo "Case runner:    ${CASE_RUNNER:-(dry-run)}"
echo "Run root:       $RUN_ROOT"
echo "Episode run id: $EPISODE_RUN_ID"

exec python3 "$EPISODE_PY" "${args[@]}" ${EXTRA:+"${EXTRA[@]}"}
