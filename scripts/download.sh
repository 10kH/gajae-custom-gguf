#!/usr/bin/env bash
# Download the model.env model (weights + optional mmproj) from Hugging Face.
# Usage: ./scripts/download.sh            download the configured files
#        ./scripts/download.sh --list     list the repo's .gguf files (pick a quant)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
# shellcheck disable=SC1090
source "${MODEL_ENV:-$ROOT/model.env}"

PY="$(resolve_python huggingface_hub)" || exit 1

if [ "${1:-}" = "--list" ]; then
  "$PY" - "$REPO" <<'PY'
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

# `hf` is the modern CLI; `huggingface-cli` is the older name; the python API is
# the always-available fallback. Any of the three gets the same files.
if need_cmd hf; then
  hf download "$REPO" "${files[@]}" --local-dir "$MODEL_DIR"
elif need_cmd huggingface-cli; then
  huggingface-cli download "$REPO" "${files[@]}" --local-dir "$MODEL_DIR"
else
  warn "no hf CLI found — falling back to the huggingface_hub python API"
  "$PY" - "$REPO" "$MODEL_DIR" "${files[@]}" <<'PY'
import sys
from huggingface_hub import hf_hub_download
repo, outdir, *files = sys.argv[1:]
for f in files:
    print(f"[download] {f}")
    hf_hub_download(repo_id=repo, filename=f, local_dir=outdir)
PY
fi
echo "[download] done."
