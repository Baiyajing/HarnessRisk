#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

CASE_ID="${1:-${DEFAULT_CASE_ID:-case_023}}"
GATEWAY_PORT="${GATEWAY_PORT:-18080}"

curl -sS -X POST "http://127.0.0.1:${GATEWAY_PORT}/admin/destroy_case" \
  -H 'Content-Type: application/json' \
  -d "{\"case_id\":\"${CASE_ID}\"}"
echo
