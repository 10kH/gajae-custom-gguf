#!/usr/bin/env bash
# Bring the whole stack up (llama-server + webp proxy for vision), idempotent.
# Usage: ./scripts/start.sh [GPU] [SPORT] [PPORT]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}"

GPU="${1:-${GPU:-0}}"; SPORT="${2:-${SPORT:-8080}}"; PPORT="${3:-${PPORT:-8081}}"
LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR"          # per-alias logs so models don't clobber each other
up(){ [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/health")" = 200 ]; }

need_cmd curl || { err "curl is required for the health checks"; exit 1; }

# ── llama-server ─────────────────────────────────────────────────────────────
if up "$SPORT"; then
  echo "[start] server already up on :$SPORT"
else
  gpu_preflight "$GPU" "$MODEL_DIR/$MODEL_FILE"
  echo "[start] launching llama-server on :$SPORT (GPU $GPU)..."
  setsid "$ROOT/scripts/serve.sh" "$GPU" "$SPORT" >"$LOGDIR/$ALIAS-server.log" 2>&1 </dev/null &
  for _ in $(seq 1 180); do up "$SPORT" && break; sleep 1; done
  up "$SPORT" && echo "[start] server ready" \
             || { err "server FAILED — tail $LOGDIR/$ALIAS-server.log"; tail -20 "$LOGDIR/$ALIAS-server.log"; exit 1; }
fi

# ── webp proxy (vision models only) ──────────────────────────────────────────
if [ -n "${MMPROJ_FILE:-}" ]; then
  if up "$PPORT"; then
    echo "[start] proxy already up on :$PPORT"
  else
    PY="$(resolve_python aiohttp PIL)" || exit 1
    echo "[start] launching webp proxy on :$PPORT ($PY)..."
    # --port/--upstream are passed as ARGV (not just env) so stop.sh can target
    # this model's proxy without killing another model's.
    setsid "$PY" -u "$ROOT/scripts/webp_proxy.py" \
      --upstream "http://127.0.0.1:$SPORT" --port "$PPORT" \
      >"$LOGDIR/$ALIAS-proxy.log" 2>&1 </dev/null &
    for _ in $(seq 1 30); do up "$PPORT" && break; sleep 1; done
    up "$PPORT" && echo "[start] proxy ready" \
                || { err "proxy FAILED — tail $LOGDIR/$ALIAS-proxy.log"; tail -20 "$LOGDIR/$ALIAS-proxy.log"; exit 1; }
  fi
  echo "[start] GJC baseUrl -> http://127.0.0.1:$PPORT/v1   (vision)"
else
  echo "[start] text-only: GJC baseUrl -> http://127.0.0.1:$SPORT/v1"
fi
