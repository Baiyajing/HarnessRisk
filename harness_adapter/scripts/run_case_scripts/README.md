# Run scripts (step 2: call agents on cases)

`run_case.sh` and `run_batch.sh` are the unified, provider-agnostic entry points
for step 2. Each works with all three harnesses (openclaw, hermes, nanobot) and
any provider/model the harness supports — nothing is hardcoded to a specific
provider. They pair with `setup_scripts/setup_agent.sh` from step 1: point them
at the state dir setup produced and they pick up provider, model, endpoint, and
the API-key env var from its env file.

```
./run_case.sh  --harness <openclaw|hermes|nanobot> [--multiturn] [options] -- <adapter args>
./run_batch.sh --harness <openclaw|hermes|nanobot> [--multiturn] [options] [DATA_DIR] -- <run_case args>
./run_case.sh --help    # full option list
./run_batch.sh --help
```

## run_case.sh — one case

Dispatches by harness:

- **openclaw** — thin wrapper over `openclaw_adapter.py run` (the adapter owns
  the mock lifecycle and turn replay). Requires Node ≥ 22.14 and a state dir
  containing `openclaw.json`.
- **hermes / nanobot** — the script drives `openclaw_adapter.py serve-mocks`,
  builds `request.json`, invokes the harness CLI (single shot or, with
  `--multiturn`, turn-by-turn replay), writes `harness_result.json`, assembles
  `trajectory/transcripts.jsonl`, then calls `openclaw_adapter.py export`.

Examples:

```bash
# OpenClaw, any provider set up via setup_agent.sh:
./run_case.sh --harness openclaw \
  --state-dir .../.openclaw-adapter/openclaw-myprovider-state \
  --model myprovider/mymodel --case-id setup_003 --data-dir <data>

# Hermes single turn:
./run_case.sh --harness hermes --model deepseek-v4-pro \
  --case-id setup_003 --data-dir <data>

# Nanobot multi-turn replay:
./run_case.sh --harness nanobot --multiturn --case-id setup_003 --data-dir <data>
```

Key options: `--state-dir`, `--env-file`, `--model`, `--provider`,
`--api-key-env`, `--cmd`, `--timeout-seconds`, `--thinking` (openclaw). Any
unrecognized flag and anything after `--` is forwarded to the adapter
(`--case-id`, `--data-dir`, `--run-root`, `--run-id`, ...).

To run against a custom harness invocation, set a runner command instead of the
built-in one: `HERMES_RUNNER_CMD`, `NANOBOT_RUNNER_CMD`, or
`NANOBOT_MULTI_TURN_RUNNER_CMD` (each receives the per-case `ADAPTER_*` env
vars).

## run_batch.sh — a data dir

Iterates single-case JSON files in `DATA_DIR`, runs each via `run_case.sh`,
writes `batch_manifest.jsonl`, then evaluates the batch into
`evaluation_summary.json`.

```bash
# OpenClaw batch:
./run_batch.sh --harness openclaw /path/to/data -- \
  --state-dir .../openclaw-myprovider-state --model myprovider/mymodel

# Hermes multi-turn batch:
./run_batch.sh --harness hermes --multiturn /path/to/data -- --model deepseek-v4-pro

# Optional sequential rate pacing (was gemini-specific, now any harness):
./run_batch.sh --harness openclaw --rate-limit-per-minute 1 --rate-match gemini \
  /path/to/data -- --model google/gemini-3.1-flash-lite
```

`--rate-match STR` counts only assistant messages whose provider/model contains
STR; empty counts all assistant API messages. Restrict cases with
`--cases "id1 id2"`; override output naming with `--batch-id` / `--batch-id-prefix`.

## Legacy scripts → unified invocation

| legacy | unified |
|---|---|
| `run_gemini_case.sh` / `run_microsoft_foundry_case.sh` / `run_claude_opus_4_7_case.sh` / `run_aiwave_gpt_5_5_case.sh` / `run_volcengine_agent_plan_case.sh` | `run_case.sh --harness openclaw --state-dir <...> --model <...>` |
| `run_hermes_case.sh` | `run_case.sh --harness hermes --model <...>` |
| `run_hermes_case_multiturn.sh` | `run_case.sh --harness hermes --multiturn --model <...>` |
| `run_nanobot_case.sh` | `run_case.sh --harness nanobot --model <...>` |
| `run_nanobot_case_multiturn.sh` | `run_case.sh --harness nanobot --multiturn --model <...>` |
| the matching `*_batch*.sh` | `run_batch.sh --harness <...> [--multiturn] ...` |

Legacy `OPENCLAW_ADAPTER_*`, `HERMES_*`, `NANOBOT_*` env vars are still honored
as defaults, so existing env files from setup keep working.

Note: the old openclaw case scripts computed paths with a fragile relative
`../..` plus `python3 openclaw_adapter/openclaw_adapter.py`, which only worked
from a specific CWD. The unified scripts resolve `openclaw_adapter.py` and
`evaluate_run.py` by absolute path from the script location, so they run
correctly regardless of CWD.

Not yet folded in: `run_foundry_jail_then_turn3_with_judge.sh` and
`run_multiseed_data_merge_128.sh` are bespoke experiment drivers, not plain
per-provider variants; leave them as-is for now.
