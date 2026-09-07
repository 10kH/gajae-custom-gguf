#!/usr/bin/env bash
# Tear down the stack for THIS model only — other models keep running.
# The llama-server is matched by --alias and the proxy by --port, both of which
# are unique per model.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}" 2>/dev/null || true

PPORT="${1:-${PPORT:-}}"

if [ -n "${MMPROJ_FILE:-}" ] && [ -n "$PPORT" ]; then
  echo "[stop] stopping webp proxy on :$PPORT..."
  kill_on_port "$PPORT"                        # by listening socket: launch-method agnostic
  safe_pkill "webp_proxy.py.*--port $PPORT"    # and by argv, in case it never bound
fi

if [ -n "${ALIAS:-}" ]; then
  echo "[stop] stopping llama-server (alias $ALIAS)..."
  safe_pkill "llama-server.*--alias $ALIAS"
else
  warn "no ALIAS in model.env — refusing to guess which llama-server to kill"
fi
sleep 1
echo "[stop] done."
