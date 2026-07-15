#!/usr/bin/env bash
# Unified, provider-agnostic single-case runner for the controlled mock benchmark.
#
# Works with all three harnesses (openclaw, hermes, nanobot) and any provider /
# model the harness supports — nothing is hardcoded to a specific provider.
#
# It pairs with setup_scripts/setup_agent.sh: point --state-dir at the state
# directory that setup produced (or rely on the env file it wrote) and this
# script picks up the provider, model, endpoint, and API-key env var from there.
#
# Replaces the per-provider case scripts:
#   run_gemini_case.sh / run_microsoft_foundry_case.sh /
#   run_claude_opus_4_7_case.sh / run_aiwave_gpt_5_5_case.sh /
#   run_volcengine_agent_plan_case.sh   -> --harness openclaw
#   run_hermes_case.sh                  -> --harness hermes
#   run_hermes_case_multiturn.sh        -> --harness hermes --multiturn
#   run_nanobot_case.sh                 -> --harness nanobot
#   run_nanobot_case_multiturn.sh       -> --harness nanobot --multiturn
set -euo pipefail

# ADAPTER_DIR is the harness_adapter package dir (contains harness_adapter.py
# and scripts/). Resolved from this script's location so the CWD never matters.
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER_PY="$ADAPTER_DIR/harness_adapter.py"

HARNESS=""
MULTITURN=0
STATE_DIR=""
ENV_FILE=""
MODEL=""
PROVIDER=""
API_KEY_ENV=""
HARNESS_CMD=""
TIMEOUT_SECONDS=""
THINKING="${OPENCLAW_ADAPTER_THINKING:-low}"
ADAPTER_ARGS=()

WORKSPACE_META_DIR="${BENCHMARK_HARNESS_META_DIR:-.benchmark_harness}"
RESULT_FILE="${BENCHMARK_HARNESS_RESULT_FILE:-harness_result.json}"
CONFIG_FILE="${BENCHMARK_HARNESS_CONFIG_FILE:-harness_config.json}"

usage() {
  cat <<EOF
Usage:
  $0 --harness <openclaw|hermes|nanobot> [options] [-- adapter/serve-mocks args...]

Required:
  --harness NAME        openclaw, hermes, or nanobot.

Common options:
  --multiturn           Replay request.messages turn-by-turn (hermes/nanobot).
                        Ignored for openclaw (the adapter already replays turns).
  --state-dir DIR       Harness state dir produced by setup_agent.sh.
                        Defaults per harness (see below); its env file is
                        auto-sourced if present.
  --env-file FILE       Explicit env file to source (overrides the default).
  --model ID            Model id / reference. Overrides the env file.
  --provider ID         Provider id / key. Overrides the env file.
  --api-key-env VAR     Name of the env var that holds the API key.
  --cmd PATH            Harness executable (hermes/nanobot).
  --timeout-seconds N   Per-invocation timeout. Default: 1800.
  --thinking LEVEL      openclaw thinking level. Default: $THINKING
  -h, --help            Show this help.

Case selection and adapter passthrough:
  Anything after -- (and any unrecognized flag) is forwarded verbatim to the
  adapter, e.g.:
    --case-id setup_003 --data-dir <dir> --run-root <dir> --run-id <id>

Per-harness state-dir defaults:
  openclaw  \$OPENCLAW_ADAPTER_MODEL_STATE_DIR
            or .openclaw-adapter/openclaw-state
  hermes    \$HERMES_ADAPTER_STATE_DIR
            or .hermes-adapter/hermes-<provider>-state
  nanobot   \$NANOBOT_ADAPTER_STATE_DIR
            or .nanobot-adapter/nanobot-state

Examples:
  # OpenClaw, any provider set up via setup_agent.sh:
  $0 --harness openclaw \\
    --state-dir "$ADAPTER_DIR/.openclaw-adapter/openclaw-myprovider-state" \\
    --model myprovider/mymodel --case-id setup_003 --data-dir <data>

  # Hermes, single turn:
  $0 --harness hermes --model deepseek-v4-pro --case-id setup_003 --data-dir <data>

  # Nanobot, multi-turn replay:
  $0 --harness nanobot --multiturn --case-id setup_003 --data-dir <data>
EOF
}

die() { echo "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:?}"; shift ;;
    --multiturn) MULTITURN=1 ;;
    --state-dir) STATE_DIR="${2:?}"; shift ;;
    --env-file) ENV_FILE="${2:?}"; shift ;;
    --model) MODEL="${2:?}"; shift ;;
    --provider) PROVIDER="${2:?}"; shift ;;
    --api-key-env) API_KEY_ENV="${2:?}"; shift ;;
    --cmd) HARNESS_CMD="${2:?}"; shift ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:?}"; shift ;;
    --thinking) THINKING="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ADAPTER_ARGS+=("$@"); break ;;
    *) ADAPTER_ARGS+=("$1") ;;
  esac
  shift
done

[[ -n "$HARNESS" ]] || { usage >&2; die "Missing --harness."; }

# CLI overrides win over anything an env file sets.
CLI_MODEL="$MODEL"
CLI_PROVIDER="$PROVIDER"
CLI_API_KEY_ENV="$API_KEY_ENV"
CLI_CMD="$HARNESS_CMD"

source_env_file() {
  local f="$1"
  [[ -n "$f" && -f "$f" ]] || return 0
  # shellcheck source=/dev/null
  source "$f"
}

check_node() {
  command -v node >/dev/null 2>&1 || die "Missing node. OpenClaw requires Node >= 22.14.0."
  node -e 'const [maj,min,patch]=process.versions.node.split(".").map(Number); process.exit(maj>22 || (maj===22 && (min>14 || (min===14 && patch>=0))) ? 0 : 1)' >/dev/null 2>&1 \
    || die "Unsupported node version: $(node --version). OpenClaw requires Node >= 22.14.0. Put a newer node first in PATH (e.g. the conda env used for setup)."
}

# ---------------------------------------------------------------------------
# OpenClaw: thin wrapper over harness_adapter.py run
# ---------------------------------------------------------------------------
run_openclaw() {
  STATE_DIR="${STATE_DIR:-${OPENCLAW_ADAPTER_MODEL_STATE_DIR:-$ADAPTER_DIR/.openclaw-adapter/openclaw-state}}"
  source_env_file "${ENV_FILE:-$STATE_DIR/openclaw-adapter.env}"
  [[ -n "$CLI_MODEL" ]] && OPENCLAW_ADAPTER_MODEL="$CLI_MODEL"
  MODEL="${OPENCLAW_ADAPTER_MODEL:-$MODEL}"

  # Map a named API key env var into CUSTOM_API_KEY when the state uses a
  # custom-api-key provider. Legacy third-party var kept as a fallback.
  if [[ -n "$CLI_API_KEY_ENV" && -z "${CUSTOM_API_KEY:-}" && -n "${!CLI_API_KEY_ENV:-}" ]]; then
    export CUSTOM_API_KEY="${!CLI_API_KEY_ENV}"
  fi
  if [[ -z "${CUSTOM_API_KEY:-}" && -n "${OPENCLAW_THIRD_PARTY_API_KEY:-}" ]]; then
    export CUSTOM_API_KEY="$OPENCLAW_THIRD_PARTY_API_KEY"
  fi

  check_node

  [[ -f "$STATE_DIR/openclaw.json" ]] || die "Missing OpenClaw state template: $STATE_DIR/openclaw.json
Run setup_scripts/setup_agent.sh --harness openclaw ... first."

  # Either an onboarded auth profile or an API key must be available.
  if [[ ! -f "$STATE_DIR/agents/main/agent/auth-profiles.json" && -z "${CUSTOM_API_KEY:-}" ]]; then
    die "No OpenClaw auth profile in $STATE_DIR and no API key in the environment.
Export the API key referenced by the provider (or CUSTOM_API_KEY), or re-run setup."
  fi

  [[ -n "$MODEL" ]] || die "Missing model. Pass --model or set OPENCLAW_ADAPTER_MODEL."

  exec python3 "$ADAPTER_PY" run \
    --mock-backend process \
    --no-start-openclaw-gateway \
    --openclaw-state-template "$STATE_DIR" \
    --model "$MODEL" \
    --thinking "$THINKING" \
    ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"}
}

# ---------------------------------------------------------------------------
# Hermes / nanobot: shell orchestrates serve-mocks + harness CLI + export
# ---------------------------------------------------------------------------
run_stdio_harness() {
  local h="$HARNESS"
  TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

  if [[ "$h" == "hermes" ]]; then
    STATE_DIR="${STATE_DIR:-${HERMES_ADAPTER_STATE_DIR:-}}"
    source_env_file "${ENV_FILE:-${HERMES_ADAPTER_ENV_PATH:-${STATE_DIR:+$STATE_DIR/hermes.env}}}"
    HARNESS_CMD="${CLI_CMD:-${HARNESS_CMD:-${HERMES_CMD:-hermes}}}"
    PROVIDER="${CLI_PROVIDER:-${HERMES_PROVIDER:-${HERMES_ADAPTER_PROVIDER:-}}}"
    MODEL="${CLI_MODEL:-${HERMES_ADAPTER_MODEL:-${HERMES_MODEL:-}}}"
    API_KEY_ENV="${CLI_API_KEY_ENV:-${HERMES_API_KEY_ENV:-}}"
    RUN_ROOT="${HERMES_ADAPTER_RUN_ROOT:-$ADAPTER_DIR/runs/hermes_adapter}"
    RUNNER_CMD="${HERMES_RUNNER_CMD:-}"
    [[ -n "$PROVIDER" ]] || die "Missing --provider for hermes (or set HERMES_PROVIDER)."
    [[ -n "$MODEL" ]] || die "Missing --model for hermes (or set HERMES_MODEL)."
  else
    STATE_DIR="${STATE_DIR:-${NANOBOT_ADAPTER_STATE_DIR:-$ADAPTER_DIR/.nanobot-adapter/nanobot-state}}"
    source_env_file "${ENV_FILE:-${NANOBOT_ADAPTER_ENV_PATH:-$STATE_DIR/nanobot.env}}"
    HARNESS_CMD="${CLI_CMD:-${HARNESS_CMD:-${NANOBOT_CMD:-nanobot}}}"
    PROVIDER="${CLI_PROVIDER:-${NANOBOT_PROVIDER:-}}"
    MODEL="${CLI_MODEL:-${NANOBOT_MODEL:-${NANOBOT_ADAPTER_MODEL:-}}}"
    API_KEY_ENV="${CLI_API_KEY_ENV:-${NANOBOT_API_KEY_ENV:-}}"
    NANOBOT_CONFIG_PATH_RESOLVED="${NANOBOT_CONFIG_PATH:-${NANOBOT_ADAPTER_CONFIG_PATH:-$STATE_DIR/nanobot_config.json}}"
    RUN_ROOT="${NANOBOT_ADAPTER_RUN_ROOT:-$ADAPTER_DIR/runs/nanobot_adapter}"
    if [[ "$MULTITURN" -eq 1 ]]; then
      RUNNER_CMD="${NANOBOT_MULTI_TURN_RUNNER_CMD:-}"
    else
      RUNNER_CMD="${NANOBOT_RUNNER_CMD:-}"
    fi
  fi

  if [[ -z "$RUNNER_CMD" ]] && ! command -v "$HARNESS_CMD" >/dev/null 2>&1; then
    die "Missing $h executable: $HARNESS_CMD
Install it, pass --cmd <path>, or set a *_RUNNER_CMD to the full command."
  fi

  if [[ -n "$API_KEY_ENV" && -z "${!API_KEY_ENV:-}" ]]; then
    die "Missing API key env var: $API_KEY_ENV
Export it before running cases, or set --api-key-env to the var your config uses."
  fi

  mkdir -p "$RUN_ROOT"
  local serve_stdout serve_stderr serve_pid run_dir harness_rc
  serve_stdout="$(mktemp)"
  serve_stderr="$(mktemp)"
  serve_pid=""
  run_dir=""
  harness_rc=1

  stop_serve() {
    local pid="${1:-}" waited=0
    if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then return 0; fi
    kill -INT "$pid" >/dev/null 2>&1 || true
    while kill -0 "$pid" >/dev/null 2>&1 && [[ "$waited" -lt 50 ]]; do sleep 0.1; waited=$((waited + 1)); done
    if kill -0 "$pid" >/dev/null 2>&1; then kill -TERM "$pid" >/dev/null 2>&1 || true; sleep 1; fi
    if kill -0 "$pid" >/dev/null 2>&1; then kill -KILL "$pid" >/dev/null 2>&1 || true; fi
    wait "$pid" >/dev/null 2>&1 || true
  }
  cleanup() { stop_serve "$serve_pid"; rm -f "$serve_stdout" "$serve_stderr"; }
  trap cleanup EXIT

  python3 "$ADAPTER_PY" serve-mocks \
    --mock-backend process \
    --run-root "$RUN_ROOT" \
    --harness "$h" \
    --workspace-meta-dir "$WORKSPACE_META_DIR" \
    --result-file "$RESULT_FILE" \
    --config-file "$CONFIG_FILE" \
    ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} >"$serve_stdout" 2>"$serve_stderr" &
  serve_pid=$!

  local run_info
  run_info="$(
    python3 - "$serve_stdout" "$serve_stderr" "$serve_pid" <<'PY'
import json, os, sys, time
from pathlib import Path
stdout_path = Path(sys.argv[1]); stderr_path = Path(sys.argv[2]); pid = int(sys.argv[3])
deadline = time.time() + 60; last_text = ""
while time.time() < deadline:
    try:
        os.kill(pid, 0)
    except OSError:
        stderr = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
        raise SystemExit(f"serve-mocks exited before printing run info:\n{stderr}")
    text = stdout_path.read_text(encoding="utf-8", errors="replace") if stdout_path.exists() else ""
    last_text = text
    if text.strip():
        try:
            info = json.loads(text)
        except json.JSONDecodeError:
            time.sleep(0.2); continue
        print(json.dumps(info)); raise SystemExit(0)
    time.sleep(0.2)
stderr = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
raise SystemExit(f"timed out waiting for serve-mocks run info\nstdout:\n{last_text}\nstderr:\n{stderr}")
PY
  )"

  run_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["run_dir"])' "$run_info")"
  local workspace gateway
  workspace="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["workspace"])' "$run_info")"
  gateway="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["gateway"])' "$run_info")"
  if [[ "$WORKSPACE_META_DIR" != ".openclaw_adapter" ]]; then
    rm -rf "$workspace/.openclaw_adapter"
  fi

  local state_dir logs_dir request_path result_path
  state_dir="$run_dir/state"
  logs_dir="$run_dir/logs"
  request_path="$run_dir/request.json"
  result_path="$run_dir/$RESULT_FILE"

  local goal
  goal="$(
    python3 - "$workspace/$WORKSPACE_META_DIR/task.md" "$run_dir/adapter_metadata.json" <<'PY'
import json, sys
from pathlib import Path
task_path = Path(sys.argv[1]); metadata_path = Path(sys.argv[2])
if task_path.exists():
    print(task_path.read_text(encoding="utf-8").strip().replace("workspace/outputs/", "outputs/"))
else:
    data = json.loads(metadata_path.read_text(encoding="utf-8"))
    print(str(data.get("goal", "")).replace("workspace/outputs/", "outputs/"))
PY
  )"

  # hermes keeps a per-run HERMES_HOME; nanobot uses the run state dir as HOME.
  local runtime_home
  if [[ "$h" == "hermes" ]]; then
    runtime_home="$state_dir/hermes-home"
  else
    runtime_home="$state_dir"
  fi

  # Build request.json (shared shape; hermes adds provider/model/home).
  H_PROVIDER="$PROVIDER" H_MODEL="$MODEL" H_HARNESS="$h" H_HOME="$runtime_home" \
  MULTITURN="$MULTITURN" \
  python3 - "$request_path" "$run_info" "$goal" "$run_dir/adapter_metadata.json" "$workspace/$WORKSPACE_META_DIR/benchmark_summary.json" <<'PY'
import json, os, sys
from pathlib import Path
request_path = Path(sys.argv[1]); info = json.loads(sys.argv[2]); goal = sys.argv[3]
metadata_path = Path(sys.argv[4]); summary_path = Path(sys.argv[5])
metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.exists() else {}
summary = json.loads(summary_path.read_text(encoding="utf-8")) if summary_path.exists() else {}
case = metadata.get("case") or {}
harness = os.environ["H_HARNESS"]

def normalize_user_messages(raw_messages):
    messages = []
    if isinstance(raw_messages, list):
        for item in raw_messages:
            if isinstance(item, str):
                text = item.strip()
            elif isinstance(item, dict):
                role = item.get("role", "user")
                if role not in ("user", "owner"):
                    continue
                text = str(item.get("content") or item.get("message") or "").strip()
            else:
                text = str(item).strip()
            if text:
                messages.append(text.replace("workspace/outputs/", "outputs/"))
    return messages

def benchmark_messages_from_case(benchmark_case):
    task = (benchmark_case or {}).get("task") or {}
    return (normalize_user_messages(task.get("user_messages"))
            or normalize_user_messages([task.get("user_message")]))

benchmark_case = {}
benchmark_case_path = summary_path.parent / "benchmark_case.json"
if benchmark_case_path.exists():
    benchmark_case = json.loads(benchmark_case_path.read_text(encoding="utf-8"))
messages = (normalize_user_messages(metadata.get("messages"))
            or benchmark_messages_from_case(benchmark_case)
            or [goal])
case_id = summary.get("case_id")
if not case_id and case.get("case_dir"):
    case_id = Path(case["case_dir"]).name
if not case_id:
    case_id = Path(info["run_dir"]).name

request = {
    "schema_version": 1,
    "harness": harness,
    "runId": Path(info["run_dir"]).name,
    "caseId": case_id,
    "goal": goal,
    "messages": messages,
    "stateDir": str(Path(info["run_dir"]) / "state"),
    "workspaceDir": info["workspace"],
    "homeDir": os.environ["H_HOME"],
    "mockGatewayBaseUrl": info["gateway"],
}
if harness == "hermes":
    request["provider"] = os.environ["H_PROVIDER"]
    request["model"] = os.environ["H_MODEL"]
if os.environ.get("MULTITURN") == "1":
    request["multi_turn_replay"] = True
request_path.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  mkdir -p "$logs_dir" "$run_dir/trajectory" "$runtime_home"

  # Shared environment for runner commands.
  export MOCK_GATEWAY_BASE_URL="$gateway"
  export BENCHMARK_HARNESS_META_DIR="$WORKSPACE_META_DIR"
  export BROWSER="${BROWSER:-echo}"
  export PATH="$workspace/bin:$PATH"

  if [[ "$h" == "hermes" ]]; then
    local shared_hermes_home="${HERMES_HOME:-}"
    if [[ -n "${HERMES_ADAPTER_CONFIG_PATH:-}" && -f "$HERMES_ADAPTER_CONFIG_PATH" ]]; then
      cp "$HERMES_ADAPTER_CONFIG_PATH" "$runtime_home/config.yaml"
    elif [[ -n "$shared_hermes_home" && -f "$shared_hermes_home/config.yaml" ]]; then
      cp "$shared_hermes_home/config.yaml" "$runtime_home/config.yaml"
    fi
    export ADAPTER_HERMES_WORKSPACE="$workspace"
    export ADAPTER_HERMES_RUN_DIR="$run_dir"
    export ADAPTER_HERMES_STATE_DIR="$state_dir"
    export ADAPTER_HERMES_SHARED_HOME="$shared_hermes_home"
    export ADAPTER_HERMES_GOAL="$goal"
    export HOME="$runtime_home"
    export HERMES_HOME="$runtime_home"
    local env_skip='HOME|PATH|HERMES_*|XDG_*|TMPDIR'
  else
    export ADAPTER_NANOBOT_WORKSPACE="$workspace"
    export ADAPTER_NANOBOT_RUN_DIR="$run_dir"
    export ADAPTER_NANOBOT_STATE_DIR="$state_dir"
    export ADAPTER_NANOBOT_GOAL="$goal"
    export ADAPTER_NANOBOT_CONFIG_PATH="$NANOBOT_CONFIG_PATH_RESOLVED"
    export HOME="$state_dir"
    local env_skip='HOME|PATH|OPENCLAW_*|XDG_*|TMPDIR'
  fi

  if [[ -f "$state_dir/.env" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        ""|\#*) continue ;;
        HOME|PATH|XDG_*|TMPDIR) continue ;;
        HERMES_*) [[ "$h" == "hermes" ]] && continue || export "$key=$value" ;;
        OPENCLAW_*) [[ "$h" == "nanobot" ]] && continue || export "$key=$value" ;;
        *) export "$key=$value" ;;
      esac
    done < "$state_dir/.env"
  fi

  echo "[$h] run dir: $run_dir"
  echo "[$h] workspace: $workspace"
  echo "[$h] mock gateway: $gateway"
  [[ "$h" == "hermes" ]] && echo "[$h] model: $PROVIDER/$MODEL"

  local turns_jsonl="$run_dir/trajectory/${h}_turns.jsonl"
  local session_id
  session_id="$(basename "$run_dir")"

  if [[ "$MULTITURN" -eq 1 ]]; then
    : > "$turns_jsonl"
    _run_turns "$h" "$request_path" "$logs_dir" "$workspace" "$turns_jsonl" "$session_id" "$goal"
    harness_rc=$?
    _write_result_multiturn "$h" "$harness_rc" "$result_path" "$turns_jsonl"
  else
    _run_single "$h" "$logs_dir" "$workspace" "$goal" "$session_id"
    harness_rc=$?
    _write_result_single "$h" "$harness_rc" "$result_path"
  fi

  _build_transcripts "$h" "$run_dir" "$goal"

  stop_serve "$serve_pid"
  serve_pid=""

  python3 "$ADAPTER_PY" export "$run_dir" \
    --goal "$goal" --harness "$h" \
    --workspace-meta-dir "$WORKSPACE_META_DIR" \
    --result-file "$RESULT_FILE" --config-file "$CONFIG_FILE"
  exit "$harness_rc"
}

# --- harness command builders (single turn) --------------------------------
_run_single() {
  local h="$1" logs_dir="$2" workspace="$3" goal="$4" session_id="$5" rc
  local out="$logs_dir/${h}_run.stdout.log" err="$logs_dir/${h}_run.stderr.log"
  set +e
  if [[ -n "$RUNNER_CMD" ]]; then
    ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" bash -lc "$RUNNER_CMD" ) >"$out" 2>"$err"
    rc=$?
  elif [[ "$h" == "hermes" ]]; then
    ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" "$HARNESS_CMD" --cli --yolo --provider "$PROVIDER" -m "$MODEL" -z "$goal" ) >"$out" 2>"$err"
    rc=$?
  else
    ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" "$HARNESS_CMD" agent --config "$ADAPTER_NANOBOT_CONFIG_PATH" --workspace "$workspace" -m "$goal" ) >"$out" 2>"$err"
    rc=$?
  fi
  set -e
  return "$rc"
}

# --- harness command builders (multi-turn replay) --------------------------
_run_turns() {
  local h="$1" request_path="$2" logs_dir="$3" workspace="$4" turns_jsonl="$5" session_id="$6" goal="$7"
  local turn_count hermes_session_id="" overall_rc=0
  turn_count="$(python3 - "$request_path" <<'PY'
import json, sys
request = json.load(open(sys.argv[1], encoding="utf-8"))
messages = request.get("messages") or [request.get("goal", "")]
print(len(messages))
PY
  )"
  [[ "$h" == "nanobot" ]] && export ADAPTER_NANOBOT_SESSION_ID="$session_id"

  set +e
  local turn_index turn_message stdout_log stderr_log rc
  for ((turn_index = 1; turn_index <= turn_count; turn_index++)); do
    turn_message="$(python3 - "$request_path" "$turn_index" <<'PY'
import json, sys
request = json.load(open(sys.argv[1], encoding="utf-8"))
messages = request.get("messages") or [request.get("goal", "")]
print(str(messages[int(sys.argv[2]) - 1]))
PY
    )"
    stdout_log="$logs_dir/${h}_turn_${turn_index}.stdout.log"
    stderr_log="$logs_dir/${h}_turn_${turn_index}.stderr.log"
    if [[ "$h" == "hermes" ]]; then
      export ADAPTER_HERMES_TURN_INDEX="$turn_index" ADAPTER_HERMES_TURN_COUNT="$turn_count" ADAPTER_HERMES_TURN_MESSAGE="$turn_message"
    else
      export ADAPTER_NANOBOT_TURN_INDEX="$turn_index" ADAPTER_NANOBOT_TURN_COUNT="$turn_count" ADAPTER_NANOBOT_TURN_MESSAGE="$turn_message"
    fi

    if [[ -n "$RUNNER_CMD" ]]; then
      ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" bash -lc "$RUNNER_CMD" ) >"$stdout_log" 2>"$stderr_log"
      rc=$?
    elif [[ "$h" == "hermes" ]]; then
      if [[ "$turn_index" -eq 1 ]]; then
        ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" "$HARNESS_CMD" chat -q "$turn_message" -Q --source benchmark-harness --cli --yolo --provider "$PROVIDER" -m "$MODEL" ) >"$stdout_log" 2>"$stderr_log"
        rc=$?
      elif [[ -z "$hermes_session_id" ]]; then
        echo "Hermes session id was not captured after turn 1; refusing independent continuation." >"$stderr_log"
        rc=2
      else
        ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" "$HARNESS_CMD" chat -q "$turn_message" -Q --resume "$hermes_session_id" --source benchmark-harness --cli --yolo --provider "$PROVIDER" -m "$MODEL" ) >"$stdout_log" 2>"$stderr_log"
        rc=$?
      fi
      if [[ "$turn_index" -eq 1 && "$rc" -eq 0 ]]; then
        local sessions_log="$logs_dir/hermes_sessions_after_turn_1.txt"
        "$HARNESS_CMD" sessions list --source benchmark-harness --limit 1 >"$sessions_log" 2>>"$stderr_log" || true
        hermes_session_id="$(python3 - "$sessions_log" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace") if Path(sys.argv[1]).exists() else ""
ids = re.findall(r"\b\d{8}_\d{6}_[0-9a-fA-F]+\b", text)
print(ids[-1] if ids else "")
PY
        )"
        if [[ -z "$hermes_session_id" ]]; then
          echo "Failed to parse Hermes session id after turn 1 from $sessions_log" >>"$stderr_log"
          rc=2
        fi
      fi
    else
      ( cd "$workspace"; timeout "$TIMEOUT_SECONDS" "$HARNESS_CMD" agent --config "$ADAPTER_NANOBOT_CONFIG_PATH" --workspace "$workspace" --session "$ADAPTER_NANOBOT_SESSION_ID" -m "$turn_message" ) >"$stdout_log" 2>"$stderr_log"
      rc=$?
    fi

    python3 - "$turns_jsonl" "$turn_index" "$turn_message" "$rc" "$stdout_log" "$stderr_log" <<'PY'
import json, sys
from pathlib import Path
path, turn, message, rc, stdout_log, stderr_log = sys.argv[1:]
response = Path(stdout_log).read_text(encoding="utf-8", errors="replace") if Path(stdout_log).exists() else ""
row = {"turn": int(turn), "message": message, "response_text": response,
       "returncode": int(rc), "stdout_log": stdout_log, "stderr_log": stderr_log}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
PY
    if [[ "$rc" -ne 0 ]]; then overall_rc="$rc"; break; fi
  done
  set -e
  return "$overall_rc"
}

_write_result_single() {
  local h="$1" rc="$2" result_path="$3"
  RC="$rc" HARNESS="$h" RESULT_PATH="$result_path" python3 - <<'PY'
import json, os
from pathlib import Path
rc = int(os.environ["RC"]); h = os.environ["HARNESS"]
result = {
    "status": "completed" if rc == 0 else "failed",
    "process_exit_code": rc,
    "harness": h,
    "stdout_log": f"logs/{h}_run.stdout.log",
    "stderr_log": f"logs/{h}_run.stderr.log",
}
Path(os.environ["RESULT_PATH"]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

_write_result_multiturn() {
  local h="$1" rc="$2" result_path="$3" turns_jsonl="$4"
  RC="$rc" HARNESS="$h" RESULT_PATH="$result_path" TURNS_JSONL="$turns_jsonl" python3 - <<'PY'
import json, os
from pathlib import Path
rc = int(os.environ["RC"]); h = os.environ["HARNESS"]
turns_path = Path(os.environ["TURNS_JSONL"])
turns = []
if turns_path.exists():
    for line in turns_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.strip():
            turns.append(json.loads(line))
response_text = turns[-1]["response_text"] if turns else ""
result = {
    "status": "completed" if rc == 0 else "failed",
    "process_exit_code": rc,
    "harness": h,
    "multi_turn_replay": True,
    "turns": turns,
    "response_text": response_text,
    "stdout_log": f"logs/{h}_turn_*.stdout.log",
    "stderr_log": f"logs/{h}_turn_*.stderr.log",
}
Path(os.environ["RESULT_PATH"]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

_build_transcripts() {
  local h="$1" run_dir="$2" goal="$3"
  RUN_DIR="$run_dir" GOAL="$goal" HARNESS="$h" MULTITURN="$MULTITURN" python3 - <<'PY'
import json, os
from pathlib import Path
run = Path(os.environ["RUN_DIR"]); h = os.environ["HARNESS"]
multiturn = os.environ.get("MULTITURN") == "1"
out_path = run / "trajectory" / "transcripts.jsonl"
rows = []

def add_lines(path, source=None):
    if not path.exists():
        return
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            entry = {"raw": line}
        rows.append({"source": str(source or path), "line": i, "entry": entry})

final_text = ""
if h == "hermes":
    if multiturn:
        add_lines(run / "trajectory" / "hermes_turns.jsonl")
        for row in rows:
            if row["entry"].get("response_text"):
                final_text = str(row["entry"]["response_text"])
    else:
        stdout_path = run / "logs" / "hermes_run.stdout.log"
        stderr_path = run / "logs" / "hermes_run.stderr.log"
        for source_path in (stdout_path, stderr_path):
            if not source_path.exists():
                continue
            for i, line in enumerate(source_path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if line.strip():
                    rows.append({"source": str(source_path), "line": i, "entry": {"raw": line}})
        final_text = stdout_path.read_text(encoding="utf-8", errors="replace").strip() if stdout_path.exists() else ""
else:  # nanobot
    session_path = run / "workspace" / "sessions" / "cli_direct.jsonl"
    add_lines(session_path)
    if multiturn:
        add_lines(run / "trajectory" / "nanobot_turns.jsonl")
    for row in rows:
        entry = row.get("entry", {})
        if entry.get("role") == "assistant" and entry.get("content"):
            final_text = str(entry.get("content") or "")

if final_text:
    rows.append({
        "source": f"{h}_final_answer",
        "line": 0,
        "entry": {"message": {"role": "assistant", "stopReason": "stop",
                              "content": [{"text": final_text, "textSignature": "final_answer"}]}},
    })
out_path.parent.mkdir(parents=True, exist_ok=True)
with out_path.open("w", encoding="utf-8") as out:
    for row in rows:
        out.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

case "$HARNESS" in
  openclaw) run_openclaw ;;
  hermes|nanobot) run_stdio_harness ;;
  *) die "Unknown harness: $HARNESS (expected openclaw, hermes, or nanobot)" ;;
esac
