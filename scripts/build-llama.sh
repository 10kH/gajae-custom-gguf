#!/usr/bin/env bash
# Build llama.cpp with CUDA (one-time per machine). No sudo needed.
# Reads CUDA_HOME / CUDA_ARCHS / LLAMA_SRC from model.env (all have defaults).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}" 2>/dev/null || true

CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-12.6}"
ARCHS="${CUDA_ARCHS:-80;90}"     # 80=A100 86=RTX30xx 89=RTX40xx 90=H100
SRC="${LLAMA_SRC:-$HOME/llama.cpp}"

[ -x "$CUDA_HOME/bin/nvcc" ] || { echo "nvcc not found at $CUDA_HOME/bin — set CUDA_HOME in model.env" >&2; exit 1; }
export PATH="$CUDA_HOME/bin:$PATH" CUDACXX="$CUDA_HOME/bin/nvcc" CUDA_PATH="$CUDA_HOME"

[ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$SRC"
cd "$SRC"
echo "[build] configuring (archs=$ARCHS)..."
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" -DLLAMA_CURL=OFF
echo "[build] compiling..."
cmake --build build -j"$(nproc)" --target llama-server llama-cli llama-mtmd-cli
echo "[build] done -> $SRC/build/bin/"
