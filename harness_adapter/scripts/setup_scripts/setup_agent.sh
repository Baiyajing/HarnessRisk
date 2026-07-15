#!/usr/bin/env bash
# Unified, provider-agnostic setup script for the controlled mock benchmark.
#
# Supports three harnesses (openclaw, hermes, nanobot). Nothing about a
# specific provider or model is hardcoded: provider id, model id(s), base URL,
# API-key env var name, context window, etc. are all supplied via CLI flags
# (or the legacy environment variables, which are still honored).
#
# Replaces:
#   setup_gemini.sh                     -> --harness openclaw --auth-choice gemini-api-key
#   setup_microsoft_foundry.sh          -> --harness openclaw --auth-choice microsoft-foundry-apikey
#   setup_claude_opus_4_7_third_party.sh\
#   setup_gemini_third_party.sh          > --harness openclaw --provider X --model Y --base-url Z
#   setup_aiwave_gpt_5_5.sh             /
#   setup_volcengine_agent_plan.sh      -> --harness openclaw --auth-choice volcengine-api-key --models-file ...
#   hermes/setup_hermes.sh              -> --harness hermes ...
#   nanobot/setup_nanobot.sh            -> --harness nanobot ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ADAPTER_ROOT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ---------------------------------------------------------------------------
# Defaults (generic; provider/model intentionally have no defaults)
# ---------------------------------------------------------------------------
HARNESS=""
PROVIDER=""
MODELS=()
MODELS_FILE=""
BASE_URL=""
API_KEY_ENV=""
STATE_DIR=""
COMPATIBILITY="openai"
AUTH_CHOICE=""
INTERACTIVE=""            # "", "0" or "1"; harness-dependent default
CONTEXT_WINDOW=200000
MAX_TOKENS=32768
INPUT_MODES="text"
API_MODE="chat_completions"   # hermes api_mode
REASONING_EFFORT="medium"     # hermes agent.reasoning_effort
OPENCLAW_API=""               # openclaw provider "api" field; derived from --compatibility if empty
HARNESS_CMD=""                # hermes / nanobot executable
RUN_ROOT=""
ALLOW_EMPTY_MODEL=0
SKIP_CLI_CHECK=0
STRICT=0
PRINT_ENV=0
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage:
  $0 --harness <openclaw|hermes|nanobot> [options] [-- <extra args>]

Generic options (all harnesses):
  --harness NAME          Required: openclaw, hermes, or nanobot.
  --provider ID           Provider id (any string the harness accepts).
  --model ID              Model id. Repeatable; comma-separated also accepted.
                          The first model is the default model.
  --models-file FILE      JSON array of model objects for multi-model
                          providers. Each entry: {"id": "...", optional
                          "name", "contextWindow", "maxTokens", "input"}.
                          Merged with --model entries.
  --base-url URL          Provider endpoint base URL.
  --api-key-env VAR       Name of the env var that holds the API key.
                          The key itself is never written into configs;
                          only the env var reference is stored.
  --state-dir DIR         Where to write harness state/config.
                          Default: \$ROOT/.<harness>-adapter/<harness>-<provider>-state
  --context-window N      Default context window for models. Default: $CONTEXT_WINDOW
  --max-tokens N          Default max output tokens. Default: $MAX_TOKENS
  --input MODES           Comma-separated input modes (openclaw). Default: $INPUT_MODES
  --print-env             Print how to source the generated env file.
  -h, --help              Show this help.

OpenClaw options:
  --auth-choice CHOICE    onboard auth choice. Default: custom-api-key.
                          Any choice OpenClaw supports is accepted
                          (e.g. gemini-api-key, microsoft-foundry-apikey,
                          volcengine-api-key, ...).
  --compatibility MODE    openai or anthropic (custom-api-key only).
                          Default: $COMPATIBILITY
  --openclaw-api API      "api" field when registering a provider block
                          (e.g. openai-completions, anthropic-messages).
                          Default: derived from --compatibility.
  --interactive           Run onboard interactively.
  --non-interactive       Run onboard non-interactively.
                          Default: non-interactive for custom-api-key,
                          interactive for other auth choices.
  Args after -- are passed through to: node scripts/run-node.mjs onboard

Hermes options:
  --cmd PATH              Hermes executable. Default: hermes
  --api-mode MODE         Default: $API_MODE
  --reasoning-effort E    Default: $REASONING_EFFORT
  --run-root DIR          Default: \$ROOT/runs/hermes_adapter
  --allow-empty-model / --skip-cli-check / --strict

Nanobot options:
  --cmd PATH              Nanobot executable. Default: nanobot
  --run-root DIR          Default: \$ROOT/runs/nanobot_adapter
  --allow-empty-model / --skip-cli-check / --strict

Environment (legacy variables still honored as defaults):
  OPENCLAW_REPO_ROOT, OPENCLAW_ADAPTER_MODEL_STATE_DIR, CUSTOM_API_KEY,
  HERMES_CMD/HERMES_MODEL/HERMES_BASE_URL/HERMES_PROVIDER/HERMES_API_KEY_ENV/
  HERMES_ADAPTER_*, NANOBOT_CMD/NANOBOT_MODEL/NANOBOT_BASE_URL/
  NANOBOT_PROVIDER/NANOBOT_API_KEY_ENV/NANOBOT_ADAPTER_*

Examples:
  # OpenClaw against any OpenAI-compatible endpoint:
  MY_KEY=... $0 --harness openclaw \\
    --provider my-provider --model my-model \\
    --base-url https://api.example.com/v1 --api-key-env MY_KEY

  # OpenClaw with a builtin auth choice plus a multi-model provider block:
  $0 --harness openclaw --auth-choice volcengine-api-key \\
    --provider volcengine-agent-plan \\
    --base-url https://ark.cn-beijing.volces.com/api/plan/v3 \\
    --api-key-env VOLCANO_ENGINE_API_KEY \\
    --models-file $SCRIPT_DIR/examples/volcengine_agent_plan_models.json

  # Hermes against any OpenAI-compatible endpoint:
  $0 --harness hermes --provider my-provider --model my-model \\
    --base-url https://api.example.com/v1 --api-key-env MY_KEY

  # Nanobot:
  $0 --harness nanobot --provider custom --model my-model \\
    --base-url https://api.example.com/v1 --api-key-env NANOBOT_API_KEY
EOF
}

die() {
  echo "$*" >&2
  exit 2
}

slugify() {
  printf '%s' "$1" | tr '/:@ ' '----' | tr -cd 'a-zA-Z0-9._-'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:?}"; shift ;;
    --provider) PROVIDER="${2:?}"; shift ;;
    --model)
      IFS=',' read -r -a _parts <<<"${2:?}"
      MODELS+=("${_parts[@]}")
      shift ;;
    --models-file) MODELS_FILE="${2:?}"; shift ;;
    --base-url) BASE_URL="${2:?}"; shift ;;
    --api-key-env) API_KEY_ENV="${2:?}"; shift ;;
    --state-dir) STATE_DIR="${2:?}"; shift ;;
    --compatibility) COMPATIBILITY="${2:?}"; shift ;;
    --auth-choice) AUTH_CHOICE="${2:?}"; shift ;;
    --openclaw-api) OPENCLAW_API="${2:?}"; shift ;;
    --interactive) INTERACTIVE=1 ;;
    --non-interactive) INTERACTIVE=0 ;;
    --context-window) CONTEXT_WINDOW="${2:?}"; shift ;;
    --max-tokens) MAX_TOKENS="${2:?}"; shift ;;
    --input) INPUT_MODES="${2:?}"; shift ;;
    --api-mode) API_MODE="${2:?}"; shift ;;
    --reasoning-effort) REASONING_EFFORT="${2:?}"; shift ;;
    --cmd) HARNESS_CMD="${2:?}"; shift ;;
    --run-root) RUN_ROOT="${2:?}"; shift ;;
    --allow-empty-model) ALLOW_EMPTY_MODEL=1 ;;
    --skip-cli-check) SKIP_CLI_CHECK=1 ;;
    --strict) STRICT=1 ;;
    --print-env) PRINT_ENV=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

[[ -n "$HARNESS" ]] || { usage >&2; die "Missing --harness."; }

if [[ -n "$MODELS_FILE" && ! -f "$MODELS_FILE" ]]; then
  die "Models file not found: $MODELS_FILE"
fi

if [[ "$COMPATIBILITY" != "openai" && "$COMPATIBILITY" != "anthropic" ]]; then
  die "--compatibility must be 'openai' or 'anthropic'."
fi

DEFAULT_MODEL="${MODELS[0]:-}"
MODELS_LIST="$(IFS=$'\n'; echo "${MODELS[*]:-}")"

# Resolved API key value (never persisted; used for validation and, for
# openclaw custom-api-key, exported as CUSTOM_API_KEY for onboarding).
api_key_value=""
if [[ -n "$API_KEY_ENV" ]]; then
  api_key_value="${!API_KEY_ENV:-}"
fi

write_env_file() {
  # write_env_file <path> <KEY=VALUE>...
  local path="$1"
  shift
  {
    echo "# Generated by setup_agent.sh."
    echo "# Source this file before running benchmark cases."
    local kv
    for kv in "$@"; do
      [[ -n "${kv#*=}" ]] || continue
      printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"
    done
  } >"$path"
  chmod 600 "$path"
}

require_cli() {
  # require_cli <cmd> <install hint>
  if [[ "$SKIP_CLI_CHECK" -eq 0 ]] && ! command -v "$1" >/dev/null 2>&1; then
    die "Missing executable: $1
Install it or pass --cmd <path>. Use --skip-cli-check if this machine only needs the config files.$2"
  fi
}

require_model_or_allow_empty() {
  if [[ "$ALLOW_EMPTY_MODEL" -eq 0 && -z "$DEFAULT_MODEL" && -z "$MODELS_FILE" ]]; then
    die "Missing --model. Use --allow-empty-model only if the harness gets the model from a separate config."
  fi
}

require_api_key_if_strict() {
  if [[ "$STRICT" -eq 1 && -z "$api_key_value" ]]; then
    die "Missing API key env var: ${API_KEY_ENV:-<unset --api-key-env>}
Export it before running strict setup."
  fi
}

api_key_note() {
  if [[ -n "$API_KEY_ENV" && -z "$api_key_value" ]]; then
    cat <<EOF

API key note:
  $API_KEY_ENV is not set in this shell. Export it before running cases.
EOF
  fi
}

print_env_hint() {
  if [[ "$PRINT_ENV" -eq 1 ]]; then
    cat <<EOF

Load it with:
  source "$1"
EOF
  fi
}

# ---------------------------------------------------------------------------
# OpenClaw
# ---------------------------------------------------------------------------
setup_openclaw() {
  local openclaw_root="${OPENCLAW_REPO_ROOT:-$HOME/openclaw/openclaw}"
  AUTH_CHOICE="${AUTH_CHOICE:-custom-api-key}"

  local state_slug
  state_slug="$(slugify "${PROVIDER:-${AUTH_CHOICE}}")"
  STATE_DIR="${STATE_DIR:-${OPENCLAW_ADAPTER_MODEL_STATE_DIR:-$ROOT_DIR/.openclaw-adapter/openclaw-${state_slug}-state}}"

  [[ -d "$openclaw_root" ]] || die "Missing OpenClaw repo: $openclaw_root (set OPENCLAW_REPO_ROOT)"
  command -v node >/dev/null 2>&1 || die "Missing node. OpenClaw requires Node >= 22.14.0."
  if ! node -e 'const [maj,min,patch]=process.versions.node.split(".").map(Number); process.exit(maj>22 || (maj===22 && (min>14 || (min===14 && patch>=0))) ? 0 : 1)' >/dev/null 2>&1; then
    die "Unsupported node version: $(node --version). OpenClaw requires Node >= 22.14.0."
  fi

  if [[ -z "$OPENCLAW_API" ]]; then
    if [[ "$COMPATIBILITY" == "anthropic" ]]; then
      OPENCLAW_API="anthropic-messages"
    else
      OPENCLAW_API="openai-completions"
    fi
  fi

  local onboard_args=(--auth-choice "$AUTH_CHOICE")
  if [[ "$AUTH_CHOICE" == "custom-api-key" ]]; then
    [[ -n "$BASE_URL" ]] || die "custom-api-key requires --base-url."
    [[ -n "$PROVIDER" ]] || die "custom-api-key requires --provider."
    [[ -n "$DEFAULT_MODEL" ]] || die "custom-api-key requires at least one --model."
    if [[ -z "${CUSTOM_API_KEY:-}" && -n "$api_key_value" ]]; then
      export CUSTOM_API_KEY="$api_key_value"
    fi
    [[ -n "${CUSTOM_API_KEY:-}" ]] || die "Missing API key. Set CUSTOM_API_KEY or pass --api-key-env VAR with VAR exported."
    INTERACTIVE="${INTERACTIVE:-0}"
    onboard_args+=(
      --custom-base-url "$BASE_URL"
      --custom-model-id "$DEFAULT_MODEL"
      --custom-provider-id "$PROVIDER"
      --custom-compatibility "$COMPATIBILITY"
    )
  else
    require_api_key_if_strict
    INTERACTIVE="${INTERACTIVE:-1}"
  fi

  if [[ "$INTERACTIVE" -eq 0 ]]; then
    onboard_args+=(
      --non-interactive
      --accept-risk
      --mode local
      --secret-input-mode ref
      --skip-channels
      --skip-skills
      --skip-search
      --skip-health
      --skip-ui
    )
  fi

  mkdir -p "$STATE_DIR"
  (
    cd "$openclaw_root"
    OPENCLAW_STATE_DIR="$STATE_DIR" \
      node scripts/run-node.mjs onboard "${onboard_args[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  )

  # Register a provider block in openclaw.json when the caller supplied
  # enough information (needed for auth choices whose onboarding does not
  # record custom providers, and for multi-model providers).
  local registered=0
  if [[ -n "$PROVIDER" && -n "$BASE_URL" ]] \
     && { [[ -n "$MODELS_FILE" ]] || [[ ${#MODELS[@]} -gt 1 ]] || [[ "$AUTH_CHOICE" != "custom-api-key" ]]; }; then
    [[ -n "$API_KEY_ENV" ]] || die "Registering a provider block requires --api-key-env (only the env var reference is stored)."
    registered=1
    STATE_DIR="$STATE_DIR" \
    PROVIDER_ID="$PROVIDER" \
    BASE_URL="$BASE_URL" \
    API_KEY_ENV="$API_KEY_ENV" \
    PROVIDER_API="$OPENCLAW_API" \
    MODELS_LIST="$MODELS_LIST" \
    MODELS_FILE="$MODELS_FILE" \
    CONTEXT_WINDOW="$CONTEXT_WINDOW" \
    MAX_TOKENS="$MAX_TOKENS" \
    INPUT_MODES="$INPUT_MODES" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

state_dir = Path(os.environ["STATE_DIR"])
provider_id = os.environ["PROVIDER_ID"]
input_modes = [m.strip() for m in os.environ["INPUT_MODES"].split(",") if m.strip()]
default_context = int(os.environ["CONTEXT_WINDOW"])
default_max_tokens = int(os.environ["MAX_TOKENS"])

def normalize(entry):
    if isinstance(entry, str):
        entry = {"id": entry}
    return {
        "id": entry["id"],
        "name": entry.get("name", entry["id"]),
        "contextWindow": entry.get("contextWindow", default_context),
        "maxTokens": entry.get("maxTokens", default_max_tokens),
        "input": entry.get("input", input_modes),
    }

models = [normalize(m) for m in os.environ["MODELS_LIST"].splitlines() if m.strip()]
models_file = os.environ.get("MODELS_FILE")
if models_file:
    file_models = json.loads(Path(models_file).read_text(encoding="utf-8"))
    if not isinstance(file_models, list):
        raise SystemExit(f"--models-file must contain a JSON array: {models_file}")
    known = {m["id"] for m in models}
    models += [normalize(m) for m in file_models
               if normalize(m)["id"] not in known]
if not models:
    raise SystemExit("No models to register (pass --model and/or --models-file).")

config_path = state_dir / "openclaw.json"
config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}

providers = config.setdefault("models", {}).setdefault("providers", {})
providers[provider_id] = {
    "baseUrl": os.environ["BASE_URL"],
    "apiKey": "${" + os.environ["API_KEY_ENV"] + "}",
    "api": os.environ["PROVIDER_API"],
    "models": models,
}

defaults = config.setdefault("agents", {}).setdefault("defaults", {})
agent_models = defaults.setdefault("models", {})
for model in models:
    agent_models.setdefault(f"{provider_id}/{model['id']}", {})
if len(models) == 1:
    defaults["model"] = f"{provider_id}/{models[0]['id']}"
else:
    defaults.pop("model", None)

config.setdefault("gateway", {})["mode"] = "local"

config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
  fi

  local default_ref=""
  if [[ -n "$PROVIDER" && -n "$DEFAULT_MODEL" ]]; then
    default_ref="$PROVIDER/$DEFAULT_MODEL"
  fi

  local env_path="$STATE_DIR/openclaw-adapter.env"
  write_env_file "$env_path" \
    "OPENCLAW_ADAPTER_MODEL_STATE_DIR=$STATE_DIR" \
    "OPENCLAW_ADAPTER_MODEL=$default_ref"

  cat <<EOF

OpenClaw state is configured at:
  $STATE_DIR

Auth choice:
  $AUTH_CHOICE
EOF
  [[ -n "$BASE_URL" ]] && printf '\nConfigured endpoint:\n  %s\n' "$BASE_URL"
  [[ -n "$default_ref" ]] && printf '\nDefault model:\n  %s\n' "$default_ref"
  if [[ "$registered" -eq 1 ]]; then
    local registered_count
    registered_count="$(python3 -c "
import json, sys
c = json.load(open(sys.argv[1]))
print(len(c['models']['providers'][sys.argv[2]]['models']))
" "$STATE_DIR/openclaw.json" "$PROVIDER")"
    printf '\nProvider block registered in openclaw.json:\n  %s (%s model(s), key from $%s)\n' \
      "$PROVIDER" "$registered_count" "$API_KEY_ENV"
  fi
  cat <<EOF

Environment file:
  $env_path

Use it with (any run script):
  OPENCLAW_ADAPTER_MODEL_STATE_DIR=$STATE_DIR${default_ref:+ OPENCLAW_ADAPTER_MODEL=$default_ref} <run_case script> --case-id <id>
EOF
  api_key_note
  print_env_hint "$env_path"
}

# ---------------------------------------------------------------------------
# Hermes
# ---------------------------------------------------------------------------
setup_hermes() {
  HARNESS_CMD="${HARNESS_CMD:-${HERMES_CMD:-hermes}}"
  PROVIDER="${PROVIDER:-${HERMES_PROVIDER:-${HERMES_ADAPTER_PROVIDER:-}}}"
  BASE_URL="${BASE_URL:-${HERMES_BASE_URL:-${HERMES_ADAPTER_BASE_URL:-}}}"
  API_KEY_ENV="${API_KEY_ENV:-${HERMES_API_KEY_ENV:-HERMES_API_KEY}}"
  if [[ -z "$DEFAULT_MODEL" && -n "${HERMES_MODEL:-${HERMES_ADAPTER_MODEL:-}}" ]]; then
    DEFAULT_MODEL="${HERMES_MODEL:-${HERMES_ADAPTER_MODEL:-}}"
    MODELS_LIST="$DEFAULT_MODEL"
  fi
  api_key_value="${!API_KEY_ENV:-}"

  [[ -n "$PROVIDER" ]] || die "Missing --provider for hermes."
  # Hermes custom providers are addressed as custom:<name>; builtin provider
  # keys (no --base-url) are used as-is.
  local provider_key="$PROVIDER"
  if [[ -n "$BASE_URL" && "$PROVIDER" != *:* ]]; then
    provider_key="custom:$PROVIDER"
  fi

  local state_slug
  state_slug="$(slugify "$PROVIDER")"
  STATE_DIR="${STATE_DIR:-${HERMES_ADAPTER_STATE_DIR:-$ROOT_DIR/.hermes-adapter/hermes-${state_slug}-state}}"
  local home_dir="${HERMES_HOME:-${HERMES_ADAPTER_HOME:-$STATE_DIR/home}}"
  local config_path="${HERMES_ADAPTER_CONFIG_PATH:-$home_dir/config.yaml}"
  local env_path="${HERMES_ADAPTER_ENV_PATH:-$STATE_DIR/hermes.env}"
  RUN_ROOT="${RUN_ROOT:-${HERMES_ADAPTER_RUN_ROOT:-$ROOT_DIR/runs/hermes_adapter}}"

  require_model_or_allow_empty
  require_cli "$HARNESS_CMD" "
Install reference:
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/install.sh | bash"
  require_api_key_if_strict

  mkdir -p "$STATE_DIR" "$home_dir" "$RUN_ROOT"

  STATE_DIR="$STATE_DIR" \
  HERMES_HOME_DIR="$home_dir" \
  CONFIG_PATH="$config_path" \
  HARNESS_CMD="$HARNESS_CMD" \
  PROVIDER_KEY="$provider_key" \
  DEFAULT_MODEL="$DEFAULT_MODEL" \
  MODELS_LIST="$MODELS_LIST" \
  MODELS_FILE="$MODELS_FILE" \
  BASE_URL="$BASE_URL" \
  API_KEY_ENV="$API_KEY_ENV" \
  API_MODE="$API_MODE" \
  REASONING_EFFORT="$REASONING_EFFORT" \
  CONTEXT_WINDOW="$CONTEXT_WINDOW" \
  RUN_ROOT="$RUN_ROOT" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

state_dir = Path(os.environ["STATE_DIR"])
config_path = Path(os.environ["CONFIG_PATH"])
provider_key = os.environ["PROVIDER_KEY"]
default_model = os.environ["DEFAULT_MODEL"]
base_url = os.environ["BASE_URL"]
api_key_env = os.environ["API_KEY_ENV"]
api_mode = os.environ["API_MODE"]
default_context = int(os.environ["CONTEXT_WINDOW"])

models = {}
for line in os.environ["MODELS_LIST"].splitlines():
    if line.strip():
        models[line.strip()] = default_context
models_file = os.environ.get("MODELS_FILE")
if models_file:
    for entry in json.loads(Path(models_file).read_text(encoding="utf-8")):
        if isinstance(entry, str):
            models.setdefault(entry, default_context)
        else:
            models.setdefault(entry["id"], entry.get("contextWindow", default_context))
if default_model:
    models.setdefault(default_model, default_context)

lines = ["# Generated by setup_agent.sh (--harness hermes)."]
lines.append("model:")
if default_model:
    lines.append(f"  default: {json.dumps(default_model)}")
lines.append(f"  provider: {json.dumps(provider_key)}")
if base_url:
    lines.append(f"  base_url: {json.dumps(base_url)}")
lines.append(f"  api_mode: {api_mode}")

if base_url:
    provider_entry = provider_key.split(":", 1)[1] if provider_key.startswith("custom:") else provider_key
    lines.append("")
    lines.append("custom_providers:")
    lines.append(f"  - name: {json.dumps(provider_entry)}")
    lines.append(f"    base_url: {json.dumps(base_url)}")
    lines.append(f"    key_env: {api_key_env}")
    lines.append(f"    api_mode: {api_mode}")
    lines.append("    models:")
    for name, context_length in sorted(models.items()):
        lines.append(f"      {name}:")
        lines.append(f"        context_length: {context_length}")

lines.append("")
lines.append("agent:")
lines.append(f"  reasoning_effort: {json.dumps(os.environ['REASONING_EFFORT'])}")

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

metadata = {
    "harness": "hermes",
    "command": os.environ["HARNESS_CMD"],
    "provider": provider_key,
    "model": default_model,
    "base_url": base_url,
    "api_key_env": api_key_env,
    "state_dir": str(state_dir),
    "home": os.environ["HERMES_HOME_DIR"],
    "config_path": str(config_path),
    "run_root": os.environ["RUN_ROOT"],
}
(state_dir / "adapter_metadata.json").write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

  write_env_file "$env_path" \
    "HERMES_HOME=$home_dir" \
    "HERMES_ADAPTER_STATE_DIR=$STATE_DIR" \
    "HERMES_ADAPTER_CONFIG_PATH=$config_path" \
    "HERMES_ADAPTER_RUN_ROOT=$RUN_ROOT" \
    "HERMES_CMD=$HARNESS_CMD" \
    "HERMES_PROVIDER=$provider_key" \
    "HERMES_API_KEY_ENV=$API_KEY_ENV" \
    "HERMES_MODEL=$DEFAULT_MODEL" \
    "HERMES_BASE_URL=$BASE_URL"

  cat <<EOF

Hermes harness configuration is ready.

State dir:
  $STATE_DIR

Hermes home:
  $home_dir

Config:
  $config_path

Environment file:
  $env_path
EOF
  [[ -n "$BASE_URL" ]] && printf '\nConfigured endpoint:\n  %s\n' "$BASE_URL"
  [[ -n "$DEFAULT_MODEL" ]] && printf '\nConfigured model:\n  %s/%s\n' "$provider_key" "$DEFAULT_MODEL"
  printf '\nRun root:\n  %s\n' "$RUN_ROOT"
  api_key_note
  print_env_hint "$env_path"
}

# ---------------------------------------------------------------------------
# Nanobot
# ---------------------------------------------------------------------------
setup_nanobot() {
  HARNESS_CMD="${HARNESS_CMD:-${NANOBOT_CMD:-nanobot}}"
  PROVIDER="${PROVIDER:-${NANOBOT_PROVIDER:-${NANOBOT_ADAPTER_PROVIDER:-custom}}}"
  BASE_URL="${BASE_URL:-${NANOBOT_BASE_URL:-${NANOBOT_ADAPTER_BASE_URL:-}}}"
  API_KEY_ENV="${API_KEY_ENV:-${NANOBOT_API_KEY_ENV:-NANOBOT_API_KEY}}"
  if [[ -z "$DEFAULT_MODEL" && -n "${NANOBOT_MODEL:-${NANOBOT_ADAPTER_MODEL:-}}" ]]; then
    DEFAULT_MODEL="${NANOBOT_MODEL:-${NANOBOT_ADAPTER_MODEL:-}}"
  fi
  api_key_value="${!API_KEY_ENV:-}"

  local state_slug
  state_slug="$(slugify "${PROVIDER}${DEFAULT_MODEL:+-$(slugify "$DEFAULT_MODEL")}")"
  STATE_DIR="${STATE_DIR:-${NANOBOT_ADAPTER_STATE_DIR:-$ROOT_DIR/.nanobot-adapter/nanobot-${state_slug}-state}}"
  local config_path="${NANOBOT_ADAPTER_CONFIG_PATH:-$STATE_DIR/nanobot_config.json}"
  local env_path="${NANOBOT_ADAPTER_ENV_PATH:-$STATE_DIR/nanobot.env}"
  RUN_ROOT="${RUN_ROOT:-${NANOBOT_ADAPTER_RUN_ROOT:-$ROOT_DIR/runs/nanobot_adapter}}"

  require_model_or_allow_empty
  require_cli "$HARNESS_CMD" ""
  require_api_key_if_strict

  mkdir -p "$STATE_DIR" "$RUN_ROOT"

  STATE_DIR="$STATE_DIR" \
  CONFIG_PATH="$config_path" \
  HARNESS_CMD="$HARNESS_CMD" \
  PROVIDER="$PROVIDER" \
  DEFAULT_MODEL="$DEFAULT_MODEL" \
  BASE_URL="$BASE_URL" \
  API_KEY_ENV="$API_KEY_ENV" \
  CONTEXT_WINDOW="$CONTEXT_WINDOW" \
  MAX_TOKENS="$MAX_TOKENS" \
  RUN_ROOT="$RUN_ROOT" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

state_dir = Path(os.environ["STATE_DIR"])
config_path = Path(os.environ["CONFIG_PATH"])

provider = os.environ["PROVIDER"]
model = os.environ["DEFAULT_MODEL"]
model_id = model.rsplit("/", 1)[-1] if "/" in model else model
api_key_env = os.environ["API_KEY_ENV"]
api_base = os.environ["BASE_URL"]

nanobot_config = {
    "providers": {
        provider: {
            "apiKey": "${" + api_key_env + "}",
        }
    },
    "modelPresets": {
        "primary": {
            "label": "Primary",
            "provider": provider,
            "model": model_id,
            "maxTokens": int(os.environ["MAX_TOKENS"]),
            "contextWindowTokens": int(os.environ["CONTEXT_WINDOW"]),
            "temperature": 0.1,
        }
    },
    "agents": {
        "defaults": {
            "modelPreset": "primary",
        }
    },
}
if api_base:
    nanobot_config["providers"][provider]["apiBase"] = api_base

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(nanobot_config, indent=2, sort_keys=True) + "\n", encoding="utf-8")

metadata = {
    "harness": "nanobot",
    "command": os.environ["HARNESS_CMD"],
    "provider": provider,
    "model": model,
    "base_url": api_base,
    "api_key_env": api_key_env,
    "state_dir": str(state_dir),
    "run_root": os.environ["RUN_ROOT"],
}
(config_path.parent / "adapter_metadata.json").write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

  write_env_file "$env_path" \
    "NANOBOT_ADAPTER_STATE_DIR=$STATE_DIR" \
    "NANOBOT_ADAPTER_CONFIG_PATH=$config_path" \
    "NANOBOT_ADAPTER_RUN_ROOT=$RUN_ROOT" \
    "NANOBOT_CMD=$HARNESS_CMD" \
    "NANOBOT_PROVIDER=$PROVIDER" \
    "NANOBOT_API_KEY_ENV=$API_KEY_ENV" \
    "NANOBOT_MODEL=$DEFAULT_MODEL" \
    "NANOBOT_BASE_URL=$BASE_URL"

  cat <<EOF

Nanobot harness configuration is ready.

State dir:
  $STATE_DIR

Config:
  $config_path

Environment file:
  $env_path

Run root:
  $RUN_ROOT
EOF
  api_key_note
  print_env_hint "$env_path"
}

case "$HARNESS" in
  openclaw) setup_openclaw ;;
  hermes) setup_hermes ;;
  nanobot) setup_nanobot ;;
  *) die "Unknown harness: $HARNESS (expected openclaw, hermes, or nanobot)" ;;
esac
