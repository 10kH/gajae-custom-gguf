#!/usr/bin/env bash
# Build llama.cpp with CUDA (one-time per machine). No sudo needed.
# CUDA toolkit and GPU architectures are AUTO-DETECTED; override in model.env
# with CUDA_HOME / CUDA_ARCHS / LLAMA_SRC if your box needs something specific.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}" 2>/dev/null || true

for c in git cmake; do need_cmd "$c" || { err "$c is required"; exit 1; }; done

CUDA_HOME="$(detect_cuda_home)" || {
  err "no CUDA toolkit found (looked at \$CUDA_HOME, nvcc on PATH, /usr/local/cuda*, \$CONDA_PREFIX)"
  err "  install one, or set CUDA_HOME in model.env to a dir containing bin/nvcc"
  exit 1
}
ARCHS="$(detect_cuda_archs)"
SRC="${LLAMA_SRC:-$HOME/llama.cpp}"

echo "[build] CUDA_HOME = $CUDA_HOME  ($("$CUDA_HOME/bin/nvcc" --version | tail -1))"
echo "[build] archs     = $ARCHS   ${CUDA_ARCHS:+(from model.env)}"
echo "[build] source    = $SRC"

export PATH="$CUDA_HOME/bin:$PATH" CUDACXX="$CUDA_HOME/bin/nvcc" CUDA_PATH="$CUDA_HOME"

[ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$SRC"
cd "$SRC"
echo "[build] configuring..."
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" -DLLAMA_CURL=OFF
echo "[build] compiling with $(ncpu) jobs..."
cmake --build build -j"$(ncpu)" --target llama-server llama-cli llama-mtmd-cli
echo "[build] done -> $SRC/build/bin/"
