#!/usr/bin/env bash
# Tear down the stack for THIS model (matched by --alias, so other models keep running).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}" 2>/dev/null || true

echo "[stop] stopping webp proxy..."
pgrep -f "python.*webp_proxy.py" | xargs -r kill 2>/dev/null || true

if [ -n "${ALIAS:-}" ]; then
  echo "[stop] stopping llama-server (alias $ALIAS)..."
  pgrep -f "llama-server.*--alias $ALIAS" | xargs -r kill 2>/dev/null || true
else
  echo "[stop] stopping llama-server (all)..."
  pgrep -f "llama-server" | xargs -r kill 2>/dev/null || true
fi
sleep 1
echo "[stop] done."
