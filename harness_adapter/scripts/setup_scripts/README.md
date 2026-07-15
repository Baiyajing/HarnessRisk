# Setup scripts

`setup_agent.sh` is the unified, provider-agnostic entry point for step 1
(setting up agents) across all three harnesses. Nothing about a specific
provider or model is hardcoded — provider id, model id(s), base URL, and the
API-key env var name are all passed in as flags. Only the env var *reference*
is stored in generated configs; the key value itself is never written to disk.

```
./setup_agent.sh --harness <openclaw|hermes|nanobot> [options] [-- <onboard args>]
./setup_agent.sh --help   # full option list
```

Outputs per harness (consumed by the step-2 run scripts):

| harness  | state dir default                                   | files written |
|----------|------------------------------------------------------|---------------|
| openclaw | `.openclaw-adapter/openclaw-<provider>-state`        | onboarded state (`openclaw.json`, ...), `openclaw-adapter.env` |
| hermes   | `.hermes-adapter/hermes-<provider>-state`            | `home/config.yaml`, `adapter_metadata.json`, `hermes.env` |
| nanobot  | `.nanobot-adapter/nanobot-<provider>-<model>-state`  | `nanobot_config.json`, `adapter_metadata.json`, `nanobot.env` |

Override the state dir with `--state-dir` to keep using an existing one.

## Examples

Any OpenAI-compatible endpoint with OpenClaw:

```bash
export MY_KEY=...
./setup_agent.sh --harness openclaw \
  --provider my-provider --model my-model \
  --base-url https://api.example.com/v1 --api-key-env MY_KEY
```

Builtin OpenClaw auth choice (interactive onboard), e.g. Gemini:

```bash
./setup_agent.sh --harness openclaw --auth-choice gemini-api-key \
  --state-dir ../../.openclaw-adapter/openclaw-gemini-state
```

Multi-model provider block (model list lives in a JSON file, not the script):

```bash
export VOLCANO_ENGINE_API_KEY=...
./setup_agent.sh --harness openclaw --auth-choice volcengine-api-key --non-interactive \
  --provider volcengine-agent-plan \
  --base-url https://ark.cn-beijing.volces.com/api/plan/v3 \
  --api-key-env VOLCANO_ENGINE_API_KEY \
  --models-file examples/volcengine_agent_plan_models.json
```

Hermes / nanobot:

```bash
./setup_agent.sh --harness hermes --provider my-provider --model my-model \
  --base-url https://api.example.com/v1 --api-key-env MY_KEY

./setup_agent.sh --harness nanobot --provider custom --model my-model \
  --base-url https://api.example.com/v1 --api-key-env NANOBOT_API_KEY
```

## Model list files

`--models-file` takes a JSON array; entries are either bare model-id strings
or objects: `{"id", "name?", "contextWindow?", "maxTokens?", "input?"}`.
Missing fields fall back to `--context-window` / `--max-tokens` / `--input`.
See `examples/volcengine_agent_plan_models.json`.

## Legacy scripts

The per-provider scripts (`setup_gemini.sh`, `setup_aiwave_gpt_5_5.sh`,
`setup_volcengine_agent_plan.sh`, `hermes/setup_hermes.sh`,
`nanobot/setup_nanobot.sh`, ...) are superseded by `setup_agent.sh` and kept
only until the unified flow is fully validated. Equivalents:

| legacy script | unified invocation |
|---|---|
| `setup_gemini.sh` | `--harness openclaw --auth-choice gemini-api-key` |
| `setup_microsoft_foundry.sh` | `--harness openclaw --auth-choice microsoft-foundry-apikey` |
| `setup_claude_opus_4_7_third_party.sh` | `--harness openclaw --provider custom-claude --model claude-opus-4-7 --base-url ... --api-key-env OPENCLAW_THIRD_PARTY_API_KEY` |
| `setup_gemini_third_party.sh` | `--harness openclaw --provider custom-gemini --model ... --base-url ... --api-key-env OPENCLAW_THIRD_PARTY_API_KEY` |
| `setup_aiwave_gpt_5_5.sh` | `--harness openclaw --provider aiwave --model gpt-5.5 --base-url https://api.ai-wave.org/v1 --api-key-env AI_WAVE_API_KEY` |
| `setup_volcengine_agent_plan.sh` | `--harness openclaw --auth-choice volcengine-api-key --non-interactive --provider volcengine-agent-plan --base-url ... --api-key-env VOLCANO_ENGINE_API_KEY --models-file examples/volcengine_agent_plan_models.json` |
| `hermes/setup_hermes.sh` | `--harness hermes --provider volcengine-agent-plan --base-url ... --api-key-env VOLCANO_ENGINE_API_KEY --model deepseek-v4-pro --models-file examples/volcengine_agent_plan_models.json` |
| `nanobot/setup_nanobot.sh` | `--harness nanobot --provider custom --model <provider/model> --base-url ...` |

Legacy `HERMES_*`, `NANOBOT_*`, `OPENCLAW_REPO_ROOT`,
`OPENCLAW_ADAPTER_MODEL_STATE_DIR` environment variables are still honored as
defaults, so existing wrapper scripts and env files keep working.
