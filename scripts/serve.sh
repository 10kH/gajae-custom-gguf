#!/usr/bin/env bash
# Serve the model.env model as an OpenAI-compatible endpoint via llama.cpp.
# Usage: ./scripts/serve.sh [GPU] [PORT]   (args override model.env)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}"

GPU="${1:-${GPU:-0}}"
PORT="${2:-${SPORT:-8080}}"
BIN="${LLAMA_BIN:-${LLAMA_SRC:-$HOME/llama.cpp}/build/bin/llama-server}"
MODEL="$MODEL_DIR/$MODEL_FILE"

[ -x "$BIN" ]   || { err "llama-server not found at $BIN — run scripts/build-llama.sh (or set LLAMA_BIN)"; exit 1; }
[ -f "$MODEL" ] || { err "model not found at $MODEL — run scripts/download.sh"; exit 1; }
gpu_preflight "$GPU" "$MODEL"

export CUDA_VISIBLE_DEVICES="$GPU"

args=(
  --model   "$MODEL"
  --alias   "$ALIAS"
  --n-gpu-layers "${NGL:-999}"
  --parallel 1
  --ctx-size "${CTX_SIZE:-65536}"
  --reasoning-budget "${REASONING_BUDGET:--1}"
  --host "${HOST:-0.0.0.0}" --port "$PORT"
  --temp "${TEMP:-0.8}" --top-p "${TOP_P:-0.95}" --top-k "${TOP_K:-40}"
  --jinja
)
# Add the vision projector only when MMPROJ_FILE is set (text-only models skip it).
if [ -n "${MMPROJ_FILE:-}" ]; then
  args+=( --mmproj "$MODEL_DIR/$MMPROJ_FILE" )
fi

echo "[serve] $ALIAS on GPU $GPU :$PORT (mmproj=${MMPROJ_FILE:-none})"
exec "$BIN" "${args[@]}"
