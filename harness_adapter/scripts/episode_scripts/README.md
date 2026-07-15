# Episode runner (cross-phase LifecycleBench episodes)

Runs an **episode** — an ordered set of subtasks that share persistent workspace
state across independent harness sessions — to measure cross-phase risk
propagation (植入 → 潜伏 → 显现 → 恢复).

These scripts are **additive**: they call the existing per-harness case runners
(`../run_case_scripts/run_<harness>_case*.sh`) through their standard
`--data-dir/--run-root/--run-id/--case-id` contract and modify nothing else.

## Files
- `episode_runner.py` — orchestrator + state carry + episode metrics.
- `run_episode.sh` — harness-agnostic entry point (`--harness NAME` → case runner).
- `aggregate_episodes.py` — aggregate seeds into PSR / CC / Latency + Wilson 95% CI.

## How state carry works
Each subtask runs as a fresh session. After subtask *i* finishes, the persistent
carrier files it left in `<run_dir>/workspace/` are read back and merged into the
seed of subtask *i+1*. Only genuine cross-session carriers are carried:

```
workspace/skills/  workspace/memory/  workspace/secrets/
workspace/config/  workspace/policies/  workspace/.state/
```

Transient paths (`inputs/`, `context/`, `outputs/`, `logs/`,
`adversarial_artifacts/`, `marketplace_notes/`) are **not** carried, so a later
benign subtask can only be affected by real persistent state — never by
re-reading the earlier attack text. Override the allowlist with repeated
`--persist-path`, or an optional `persist_paths` array in the episode JSON.

Mock-service state (accumulating webhook posts, marketplace install list) is
carried only with `--carry-mock-services`.

## Quick start

Validate the whole pipeline offline (no model/API needed):
```bash
bash run_episode.sh --episode ../../../case_data/episode/epA_001.json --dry-run \
  --run-root /tmp/ep_dry
```

Live single-episode pilot (example: OpenClaw / Claude-Opus-4.7 runner):
```bash
# export whatever the chosen case runner needs (API keys, model env), then:
bash run_episode.sh \
  --episode ../../../case_data/episode/epA_001.json \
  --harness claude_opus_4_7 \
  --episode-run-id epA_001-opus-seed1 \
  --run-root ../../runs/episode_adapter
```

Hermes / Nanobot use the two-phase runners; add `--multiturn` to prefer the
`_multiturn` variant so each subtask replays its `task.user_messages`:
```bash
bash run_episode.sh --episode ../../../case_data/episode/epA_001.json \
  --harness hermes --multiturn --run-root ../../runs/episode_adapter
```

Aggregate across seeds/episodes:
```bash
python3 aggregate_episodes.py ../../runs/episode_adapter
```

## Outputs (per episode run)
```
<run-root>/<episode-run-id>/
  derived_cases/<subtask>/<subtask>.json   # per-subtask seed after carry
  <subtask>/                               # standard harness run_dir
  episode_result.json                      # per-subtask + episode metrics
```

`episode_result.json.episode_metrics`: `inject_success`, `propagation_success`
(PSR numerator, defined only when inject succeeded), `latency_subtasks`,
`cleanup_completeness`, `persistence_under_recovery`, `first_detection_subtask_index`.
