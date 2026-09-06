#!/usr/bin/env bash
# Download the model.env model (weights + optional mmproj) from Hugging Face.
# Usage: ./scripts/download.sh            download the configured files
#        ./scripts/download.sh --list     list the repo's .gguf files (pick a quant)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${MODEL_ENV:-$ROOT/model.env}"

if [ "${1:-}" = "--list" ]; then
  python - "$REPO" <<'PY'
import sys
from huggingface_hub import HfApi
for f in HfApi().list_repo_files(sys.argv[1]):
    if f.endswith(".gguf"):
        print(f)
PY
  exit 0
fi

mkdir -p "$MODEL_DIR"
files=( "$MODEL_FILE" )
[ -n "${MMPROJ_FILE:-}" ] && files+=( "$MMPROJ_FILE" )
echo "[download] $REPO -> $MODEL_DIR"
hf download "$REPO" "${files[@]}" --local-dir "$MODEL_DIR"
echo "[download] done."
