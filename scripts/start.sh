#!/usr/bin/env bash
# Bring the whole stack up (llama-server + webp proxy for vision), idempotent.
# Usage: ./scripts/start.sh [GPU] [SPORT] [PPORT]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${MODEL_ENV:-$ROOT/model.env}"

GPU="${1:-${GPU:-0}}"; SPORT="${2:-${SPORT:-8080}}"; PPORT="${3:-${PPORT:-8081}}"
up(){ [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/health")" = 200 ]; }

# --- llama-server ---
if up "$SPORT"; then
  echo "[start] server already up on :$SPORT"
else
  echo "[start] launching llama-server on :$SPORT (GPU $GPU)..."
  setsid "$ROOT/scripts/serve.sh" "$GPU" "$SPORT" >"$ROOT/server.log" 2>&1 </dev/null &
  for i in $(seq 1 180); do up "$SPORT" && break; sleep 1; done
  up "$SPORT" && echo "[start] server ready" \
             || { echo "[start] server FAILED — tail $ROOT/server.log"; tail -20 "$ROOT/server.log"; exit 1; }
fi

# --- webp proxy (vision models only) ---
if [ -n "${MMPROJ_FILE:-}" ]; then
  if up "$PPORT"; then
    echo "[start] proxy already up on :$PPORT"
  else
    echo "[start] launching webp proxy on :$PPORT..."
    if [ -n "${CONDA_ENV:-}" ] && [ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]; then
      # shellcheck disable=SC1091
      source "$HOME/miniforge3/etc/profile.d/conda.sh"; conda activate "$CONDA_ENV"
    fi
    PROXY_PORT="$PPORT" UPSTREAM="http://127.0.0.1:$SPORT" \
      setsid python -u "$ROOT/scripts/webp_proxy.py" >"$ROOT/proxy.log" 2>&1 </dev/null &
    for i in $(seq 1 30); do up "$PPORT" && break; sleep 1; done
    up "$PPORT" && echo "[start] proxy ready" \
                || { echo "[start] proxy FAILED — tail $ROOT/proxy.log"; tail -20 "$ROOT/proxy.log"; exit 1; }
  fi
  echo "[start] GJC baseUrl -> http://127.0.0.1:$PPORT/v1   (vision)"
else
  echo "[start] text-only: GJC baseUrl -> http://127.0.0.1:$SPORT/v1"
fi
