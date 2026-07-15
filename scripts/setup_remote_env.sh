#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required on the remote server." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required on the remote server." >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
fi

set -a
. ./.env
set +a

chmod 700 scripts
chmod +x scripts/*.sh
chmod 600 .env

echo "Starting controlled mock services. Only mock_gateway is bound to 127.0.0.1 by default."
docker compose up -d --build

echo "Resetting default case..."
"$ROOT_DIR/scripts/reset_case.sh" "${DEFAULT_CASE_ID:-case_023}"

echo "Done. Gateway: http://127.0.0.1:${GATEWAY_PORT:-18080}"
