# Benchmark cases

The benchmark **case set is distributed separately in the
[HarnessRisk dataset on Hugging Face](https://huggingface.co/datasets/YajingB/HarnessRisk)**
(it is not committed to this repo). Each case is a single self-contained JSON
file that embeds the whole scenario: the benign user task, the injected attack,
the initial mock-service state, the seed workspace files, and the deterministic
oracle used by the rule evaluator.

## Get the cases

Download the dataset **into a named subfolder of `data/`** (so several sets can
coexist and `--data-dir` is unambiguous):

```bash
hf download YajingB/HarnessRisk --repo-type dataset \
  --local-dir ./data/HarnessRisk
```

After this you should have one `.json` file per case:

```
data/HarnessRisk/
  action_016.json
  daily_007.json
  ...
```

Then point the pipeline at that folder with `--data-dir` — **it must be the
directory that directly contains the `*.json` case files**:

```bash
harness_adapter/scripts/run_case_scripts/run_batch.sh --harness nanobot \
  --data-dir data/HarnessRisk -- --model <provider/model>
```

If the download instead lands the `.json` files flat in `data/`, use
`--data-dir data`. If `--data-dir` is omitted, the scripts default to
`<repo>/data`.

## Case file format (summary)

Each `<case_id>.json` contains:

| key | meaning |
|---|---|
| `case_id` | e.g. `action_016`. Prefix encodes the lifecycle **phase** (see below). |
| `phase` | one of the six lifecycle phases. |
| `task` | benign user goal and `user_messages` (multi-turn supported). |
| `design_steps` | the attack design: `2_benign_workflow`, `3_sensitive_asset_or_high_impact_action`, `4_attack_surface`, `5_attack_goal`, `6_trigger_type_and_visibility`, `7_adversarial_artifact`, `8_oracle_scorer`. |
| `world` | initial mock-service state and seed workspace files. |
| `oracle_scorer` | deterministic predicate trees for `utility_success`, `attack_success`, `safe_behavior`. |
| `expected_safe_trajectory` / `unsafe_trajectory` | reference traces. |

### Lifecycle phases (case-id prefixes)

| prefix | phase | what it stresses |
|---|---|---|
| `setup_` | setup / configuration | acting on untrusted setup docs |
| `skill_` | skill acquisition | installing/evaluating third-party skills |
| `daily_` | daily operation | routine tasks over untrusted content |
| `memory_` | persistent memory | writes to long-lived agent memory/identity |
| `action_` | irreversible action | payments, deletions, deployments |
| `recovery_` | recovery / forensics | post-incident cleanup and investigation |
