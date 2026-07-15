# Evaluate (step 3: LLM-as-judge over collected evidence)

`llm_judge_multi_harness_batch_aiwave.py` is the canonical evaluator. It reads
the run directories produced by step 2 (`run_case.sh` / `run_batch.sh`), builds
one harness-neutral **evidence bundle** per case, and asks an LLM judge to score
four binary metrics: `utility_score`, `attack_success_rate`, `persistence_score`,
`detection_score`.

## Works with all three harnesses

Every harness funnels through `openclaw_adapter.py export`, so the on-disk
evidence layout (`trajectory/trajectory.json`, `transcripts.jsonl`,
`tool_calls.jsonl`, `workspace_diff.json`, `network_events.json`, ...) is
uniform. The judge normalizes the per-harness transcript shapes:

- **openclaw** — `entry.message` with content parts / `final_answer` signature.
- **nanobot** — session rows (`workspace/sessions/cli_direct.jsonl`) + synthetic
  final answer.
- **hermes** — Hermes keeps its transcript in a state DB, so `export` often
  writes an **empty** `transcripts.jsonl`. The judge detects this and falls back
  to reconstructing the conversation from `harness_result.json` (per-turn
  `message`/`response_text`), `request.json` messages, and the run's stdout log.
  The evidence field `conversation_source` records which path was used
  (`transcripts.jsonl` vs `fallback:harness_result`).

Verified against real runs: openclaw and nanobot parse from transcripts;
hermes populates via the fallback. So no separate transcript-export step is
required before judging (the older `export_hermes_state_db_transcripts.py`
remains available if you want the full state-DB transcript instead).

## Calling the LLM (convenient for others)

The judge uses the standard `openai` SDK against any OpenAI-compatible endpoint.
It defaults to AI Wave `gpt-5.4`, but everything is overridable and the API key
is read from `AIWAVE_API_KEY` **or** `OPENAI_API_KEY` (or `--api-key`).

```bash
pip install openai

# Default (AI Wave gpt-5.4):
export AIWAVE_API_KEY=...        # or OPENAI_API_KEY
python llm_judge_multi_harness_batch_aiwave.py <batch_run_dir> --completed-only

# Any other OpenAI-compatible endpoint / model:
python llm_judge_multi_harness_batch_aiwave.py <batch_run_dir> \
  --base-url https://api.openai.com/v1 --deployment gpt-5.4 --api-key-env OPENAI_API_KEY

# Build evidence bundles only, no LLM call (no key needed):
python llm_judge_multi_harness_batch_aiwave.py <batch_run_dir> --dry-run
```

Endpoint/model/key resolution (all overridable on the CLI):

| what | flag | env fallback | default |
|---|---|---|---|
| endpoint | `--base-url` | `AIWAVE_BASE_URL`, `OPENAI_BASE_URL` | AI Wave `/v1` |
| model | `--deployment` | `AIWAVE_MODEL`, `OPENAI_MODEL` | `gpt-5.4` |
| API key | `--api-key` | `--api-key-env` (default `AIWAVE_API_KEY`), then `OPENAI_API_KEY` | — |

If the key is missing the judge raises a clear error naming the env vars to set;
if `openai` isn't installed it points you at `pip install openai` or `--dry-run`.
Errors are recorded per case (the batch continues and still writes `summary.json`).

## Output

Under `<batch_run_dir>/llm_judge_multi_harness/` (override with `--output-dir`):

- `evidence/<case_id>.json` — the evidence bundle sent to the judge.
- `results/<case_id>.json` — the judge's JSON verdict per case (cached; re-run
  with `--overwrite` to refresh).
- `manifest.json` — per-run status (`judged` / `existing` / `error` / ...).
- `summary.json` — averaged metrics + agreement vs the rule evaluator.
- `llm_vs_rule_evaluator.csv` — per-case LLM vs rule metrics.

Useful filters: `--completed-only`, `--case-id ID` (repeatable),
`--harness NAME` (repeatable), `--limit N`, `--sleep-seconds S` (pace calls).

## Other files in this dir

`llm_judge_batch.py` / `llm_judge_batch_aiwave.py` are older single-format
variants; `llm_judge_multi_harness_batch.py` is the pre-AI-Wave multi-harness
version. `analyze_llm_judge_results.py` and `merge_llm_judge_aiwave_results.py`
post-process the results; `export_hermes_state_db_transcripts.py` extracts full
Hermes state-DB transcripts when the fallback conversation isn't enough.
