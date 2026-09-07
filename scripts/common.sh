#!/usr/bin/env bash
# Shared environment discovery. Sourced by the other scripts; not run directly.
#
# Everything here exists so the repo works on ANY CUDA box rather than the
# author's: conda, python and the CUDA toolkit are DISCOVERED, never assumed.
# Each helper honours an explicit override from model.env, so a weird layout is
# always expressible: CONDA_SH, PYTHON, CUDA_HOME, CUDA_ARCHS.

warn(){ echo "[warn] $*" >&2; }
err(){  echo "[error] $*" >&2; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
ncpu(){ nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# ── process control ──────────────────────────────────────────────────────────
# This process plus every ancestor, as " pid pid pid ". Killing an ancestor is
# how a naive `pkill -f webp_proxy.py` takes down the terminal that launched it:
# the shell's own command line contains the pattern.
_ancestor_pids() {
  local p="$PPID" out=" $$ $PPID "
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    out="$out$p "
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  echo "$out"
}

safe_kill_pids() {
  local anc pid; anc="$(_ancestor_pids)"
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    case "$anc" in *" $pid "*) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done
}

# Kill by `pgrep -f` pattern, never self or an ancestor.
safe_pkill() { safe_kill_pids $(pgrep -f "$1" 2>/dev/null || true); }

# Echo the PID listening on a TCP port. Port-based targeting works no matter how
# the process was launched, so it also catches instances started by an older
# version of these scripts.
pid_on_port() {
  local port="$1"
  if need_cmd ss; then
    ss -lptnH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1
  elif need_cmd lsof; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1
  fi
}

kill_on_port() { safe_kill_pids $(pid_on_port "$1"); }

# ── conda ────────────────────────────────────────────────────────────────────
# Echo the path to a conda.sh from any common install. Override: CONDA_SH.
find_conda_sh() {
  local c base
  for c in "${CONDA_SH:-}" \
           "$HOME/miniforge3/etc/profile.d/conda.sh" \
           "$HOME/mambaforge/etc/profile.d/conda.sh" \
           "$HOME/miniconda3/etc/profile.d/conda.sh" \
           "$HOME/anaconda3/etc/profile.d/conda.sh" \
           "/opt/conda/etc/profile.d/conda.sh" \
           "/usr/local/conda/etc/profile.d/conda.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  if [ -n "${CONDA_EXE:-}" ]; then
    base="$(dirname "$(dirname "$CONDA_EXE")")"
    [ -f "$base/etc/profile.d/conda.sh" ] && { echo "$base/etc/profile.d/conda.sh"; return 0; }
  fi
  if need_cmd conda; then
    base="$(conda info --base 2>/dev/null || true)"
    [ -n "$base" ] && [ -f "$base/etc/profile.d/conda.sh" ] && { echo "$base/etc/profile.d/conda.sh"; return 0; }
  fi
  return 1
}

# ── python ───────────────────────────────────────────────────────────────────
# Echo an ABSOLUTE python path (absolute matters: callers use it after the
# subshell that ran `conda activate` is gone). Override: PYTHON.
find_python() {
  local py
  for py in "${PYTHON:-}" python3 python; do
    [ -n "$py" ] || continue
    need_cmd "$py" && { command -v "$py"; return 0; }
  done
  return 1
}

# Resolve a python that can import the given modules, activating CONDA_ENV when
# one is configured and findable. Fails LOUDLY with the exact pip line to run —
# a silent fallback to a dependency-less interpreter is the failure mode this
# whole function exists to prevent.
#   PY="$(resolve_python aiohttp PIL)" || exit 1
resolve_python() {
  local sh py missing hint
  if [ -n "${CONDA_ENV:-}" ]; then
    if sh="$(find_conda_sh)"; then
      # shellcheck disable=SC1090
      source "$sh"
      conda activate "$CONDA_ENV" 2>/dev/null \
        || warn "conda env '$CONDA_ENV' not found under $(dirname "$(dirname "$sh")") — trying system python"
    else
      warn "no conda install found — set CONDA_SH or PYTHON in model.env if you need one"
    fi
  fi
  py="$(find_python)" || { err "no python interpreter (tried \$PYTHON, python3, python)"; return 1; }
  if [ "$#" -gt 0 ]; then
    missing="$("$py" - "$@" <<'PY' 2>/dev/null || true
import importlib.util, sys
print(" ".join(m for m in sys.argv[1:] if importlib.util.find_spec(m) is None))
PY
)"
    if [ -n "$missing" ]; then
      hint="${missing//PIL/Pillow}"          # import name -> pip name
      err "$py cannot import: $missing"
      err "  fix:  $py -m pip install $hint"
      err "  or point CONDA_ENV / PYTHON (model.env) at an interpreter that has them"
      return 1
    fi
  fi
  echo "$py"
}

# ── cuda ─────────────────────────────────────────────────────────────────────
# Highest CUDA version this DRIVER can run (nvidia-smi's "CUDA Version: X.Y").
driver_cuda_max() {
  need_cmd nvidia-smi || return 0
  nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+\.[0-9]+' | head -1
}
_ver_le(){ [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# Echo a CUDA toolkit dir containing bin/nvcc, newest first but never newer than
# the driver supports (a toolkit the driver can't run builds a binary that won't
# start). Override: CUDA_HOME.
detect_cuda_home() {
  local d v dmax
  if [ -n "${CUDA_HOME:-}" ] && [ -x "$CUDA_HOME/bin/nvcc" ]; then echo "$CUDA_HOME"; return 0; fi
  if need_cmd nvcc; then dirname "$(dirname "$(command -v nvcc)")"; return 0; fi
  dmax="$(driver_cuda_max)"
  for d in $(ls -d /usr/local/cuda-*/ 2>/dev/null | sort -Vr); do   # newest first
    d="${d%/}"
    [ -x "$d/bin/nvcc" ] || continue
    v="$(basename "$d")"; v="${v#cuda-}"
    # accepts both "13" and "13.0" — the dir is sometimes a major-only symlink
    if [ -n "$dmax" ] && printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)*$' && ! _ver_le "$v" "$dmax"; then
      warn "skipping CUDA $v — driver supports only up to $dmax"
      continue
    fi
    echo "$d"; return 0
  done
  [ -x /usr/local/cuda/bin/nvcc ] && { echo /usr/local/cuda; return 0; }
  [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/nvcc" ] && { echo "$CONDA_PREFIX"; return 0; }
  return 1
}

# Echo CMAKE_CUDA_ARCHITECTURES for the GPUs actually present (e.g. "80;90").
# Override: CUDA_ARCHS. Falls back to "native" when nvidia-smi can't say.
detect_cuda_archs() {
  local caps
  if [ -n "${CUDA_ARCHS:-}" ]; then echo "$CUDA_ARCHS"; return 0; fi
  if need_cmd nvidia-smi; then
    caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
            | tr -d ' .' | grep -E '^[0-9]+$' | sort -u | paste -sd';' -)"
    [ -n "$caps" ] && { echo "$caps"; return 0; }
  fi
  echo "native"
}

# ── gpu preflight ────────────────────────────────────────────────────────────
gpu_count(){ need_cmd nvidia-smi && nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l || echo 0; }
gpu_max_free_mib(){ need_cmd nvidia-smi && nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | sort -rn | head -1 || echo 0; }

# Warn (never block) about obvious problems before a multi-minute model load.
# NOTE: GPU is a CUDA_VISIBLE_DEVICES index, whose ordering can differ from
# nvidia-smi's on multi-GPU boxes — so the VRAM check looks at the roomiest
# card rather than pretending to know which one you'll land on.
gpu_preflight() {
  local idx="${1:-0}" model="${2:-}" n free need
  n="$(gpu_count)"
  if [ "$n" -eq 0 ]; then
    warn "no NVIDIA GPU visible — llama.cpp will run on CPU (very slow)"
    return 0
  fi
  if [ "$idx" -ge "$n" ] 2>/dev/null; then
    warn "GPU=$idx but only $n device(s) present (valid indices 0..$((n-1)))"
  fi
  if [ -n "$model" ] && [ -f "$model" ]; then
    need=$(( $(stat -c%s "$model" 2>/dev/null || echo 0) / 1048576 ))
    free="$(gpu_max_free_mib)"
    if [ "$need" -gt 0 ] && [ "$free" -gt 0 ] && [ "$free" -lt "$need" ]; then
      warn "roomiest GPU has ${free}MiB free but the model is ${need}MiB — expect partial offload or OOM"
      warn "  (pick a smaller quant, or lower NGL to keep some layers on CPU)"
    fi
  fi
  return 0
}
