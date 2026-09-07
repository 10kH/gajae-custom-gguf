# gajae-custom-gguf

Serve **any** GGUF model — text **or** vision — locally with a CUDA `llama.cpp`,
and register it in [gajae-code](https://github.com/) (GJC) as a first-class
model. Model-agnostic: you fill in **one config file** (`model.env`) and every
script reads from it. Includes the fix for the **WebP image gotcha** that
otherwise breaks vision in GJC. No `sudo` required.

> Distilled from a real setup (Gemma-4-31B multimodal on an A100). Verified on:
> Ubuntu 22.04, CUDA toolkit 12.6, A100 80GB, GJC v0.7.9, `llama.cpp` master.
> Only the GJC-registration step (§5) and CLI flags (§6) are version-coupled —
> the whole serving half is version-independent, and §5 ships a self-check.

---

## TL;DR

```bash
git clone https://github.com/10kH/gajae-custom-gguf.git
cd gajae-custom-gguf
cp examples/gemma-4-31b-vision.env model.env    # or model.env.example, then edit
$EDITOR model.env                               # set REPO / MODEL_FILE / ALIAS / GPU ...

./scripts/build-llama.sh        # one-time per machine (CUDA llama.cpp)
./scripts/download.sh           # pull the gguf(s) from Hugging Face
./scripts/start.sh              # llama-server (+ webp proxy for vision)
./scripts/render-gjc-config.sh  # prints the provider block -> merge into ~/.gjc/agent/models.yml

gjc --model <ALIAS>-local/<ALIAS> --thinking xhigh
gjc --model <ALIAS>-local/<ALIAS> @photo.png "Describe this image."
```

---

## Repo layout

| Path | What |
|------|------|
| `model.env.example` | the one config file — copy to `model.env`, fill in once |
| `examples/*.env` | ready-made configs (vision + text-only) |
| `scripts/common.sh` | environment discovery (conda/python/CUDA/GPU) shared by the rest |
| `scripts/build-llama.sh` | build CUDA `llama.cpp` (one-time per machine) |
| `scripts/download.sh` | fetch weights (+ mmproj) from Hugging Face; `--list` shows quants |
| `scripts/serve.sh` | run llama-server from `model.env` (no hardcoding) |
| `scripts/start.sh` / `stop.sh` | bring the stack up/down, idempotent, per-model |
| `scripts/webp_proxy.py` | WebP→PNG proxy — **required for vision in GJC** (§7) |
| `scripts/render-gjc-config.sh` | generate the GJC provider YAML from `model.env` |
| `scripts/client.py` | direct OpenAI client (full-res vision, bypasses GJC) |
| `gjc/models.snippet.yml` | reference provider block with placeholders |

---

## 0. The config file

Everything is driven by `model.env`. Copy the template (or an example) and edit:

```bash
cp model.env.example model.env
```

| Key | Meaning |
|-----|---------|
| `REPO` / `MODEL_FILE` | Hugging Face repo id + the quant to download |
| `MMPROJ_FILE` | vision projector — **leave empty for text-only** (skips the proxy) |
| `ALIAS` | short id used everywhere (server `--alias` **and** GJC model id) |
| `MODEL_DIR` | where the `.gguf` files live |
| `GPU` / `SPORT` / `PPORT` | CUDA device / server port / proxy port |
| `CTX_SIZE` / `REASONING_BUDGET` | one big slot + unrestricted thinking |
| `TEMP` / `TOP_P` / `TOP_K` | sampling (use the model card's values) |

Pick a quant by VRAM: `Q8_0` (~lossless, big) · `Q6_K` (excellent) · `Q4_K_M`
(fits small GPUs). Rule of thumb: VRAM ≈ file size + a few GB for the KV cache.
Run a **second** model from another env with `MODEL_ENV=other.env ./scripts/start.sh`.

---

## 1. Prerequisites (no sudo)

A C/C++ compiler, `git`, `cmake`, `curl`, a **CUDA toolkit** (`nvcc`), and a
python with a few packages. You do **not** need to tell the scripts where any of
it lives — see [Portability](#portability).

```bash
gcc --version; git --version; cmake --version
nvidia-smi                                 # confirm driver + GPUs

conda create -y -n gguf python=3.11        # any python works; conda is just convenient
conda activate gguf
pip install -U huggingface_hub Pillow aiohttp openai
```

The GPU driver's CUDA version can be newer than the toolkit — that's fine
(backward compatible). The reverse is not, and the build script checks for it.

---

## 2. Build llama.cpp with CUDA (one-time)

```bash
./scripts/build-llama.sh
```

The CUDA toolkit and your GPUs' compute capabilities are **auto-detected** — no
editing required for a normal box. Binaries land in `~/llama.cpp/build/bin/`.

> **Why build from source** instead of Ollama/prebuilt wheels? Brand-new
> architectures land in `llama.cpp` master first; old Ollama / lagging pip wheels
> silently fail to load them. Check support:
> `grep -riE "your_arch" ~/llama.cpp/src/llama-arch.cpp` (e.g. `gemma4`, `qwen3`).

---

## 3. Download the model

```bash
./scripts/download.sh            # pulls MODEL_FILE (+ MMPROJ_FILE)
./scripts/download.sh --list     # unsure of the exact filename? list the repo's ggufs
```

---

## 4. Serve it

```bash
./scripts/start.sh               # idempotent; starts server (+ proxy for vision)
curl -s http://127.0.0.1:8080/v1/models     # sanity check — should list your ALIAS
./scripts/stop.sh                # tear down (matched by --alias; other models keep running)
```

`serve.sh` runs with `--parallel 1 --ctx-size <CTX_SIZE>` (one big slot so long
"thinking" is never truncated) and `--reasoning-budget -1` (unrestricted). For
vision, `start.sh` also launches the WebP proxy (§7). Logs go to
`logs/<ALIAS>-{server,proxy}.log`.

**Several models at once** — give each its own env file and ports:

```bash
MODEL_ENV=./other-model.env ./scripts/start.sh     # SPORT/PPORT differ in that file
MODEL_ENV=./other-model.env ./scripts/stop.sh      # stops only that model
```

`stop.sh` targets the llama-server by its `--alias` and the proxy by its
listening port, so stopping one model never touches another.

---

## 5. Register in GJC — `~/.gjc/agent/models.yml`

Generate the provider block from your config and merge it in (don't duplicate the
top-level `providers:` key):

```bash
./scripts/render-gjc-config.sh              # prints the exact YAML for your model
```

It emits (vision example):

```yaml
providers:
  <ALIAS>-local:
    baseUrl: http://127.0.0.1:8081/v1     # proxy port (:8080 directly if text-only)
    api: openai-completions               # -> /v1/chat/completions
    auth: none
    models:
      - id: <ALIAS>                        # MUST match llama-server --alias
        name: <ALIAS> (local)
        input: [text, image]              # [text] only for text-only models
        reasoning: true
        thinking: { minLevel: low, maxLevel: xhigh, mode: effort,
                    defaultLevel: high, levels: [low, medium, high, xhigh] }
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        contextWindow: 65536
        maxTokens: 32768
```

### Stay valid across GJC updates (self-check)

Only this section and §6's flags are coupled to GJC's version. After **any** GJC
upgrade, run this — it tells you if the strict schema drifted and which key broke:

```bash
# schema OK if GJC still sees the model (exit 0):
gjc --list-models 2>&1 | grep -q "<ALIAS>" && echo "OK" || echo "DRIFT — read the error"
# surface the validation error (names the offending key):
gjc --list-models 2>&1 | grep -iE "error|invalid|unknown|expected|schema" || true
```

If a key is rejected it was **renamed/removed**, not gone from reality: find its
new name in GJC's built-in provider configs (`gjc --help`, and the YAML under
`~/.gjc`), and rename yours to match. **Fallback:** strip your entry to the
minimal set (`baseUrl`, `api`, `auth`, `models[].id/name/input`), confirm it
loads, then re-add `thinking`/`cost`/etc. one at a time.

---

## 6. Use it

```bash
gjc --model <ALIAS>-local/<ALIAS> --thinking xhigh          # text, max thinking
gjc --model <ALIAS>-local/<ALIAS> @photo.png "What is this?" # vision (@ = attach file)
gjc -p --model <ALIAS>-local/<ALIAS> "Explain X step by step."  # non-interactive

python scripts/client.py "describe this" ./photo.jpg         # full-res, bypasses GJC
```

In a running session: **Ctrl+P** switches model, **Ctrl+T** folds the thinking
trace, **Shift+Tab** cycles thinking level.

---

## 7. Why the WebP proxy? (the vision gotcha)

GJC re-encodes every attached image to **WebP** before sending. But `llama.cpp`'s
multimodal loader uses `stb_image`, which handles **jpg/png/bmp/gif but NOT
webp** → the server returns `400 Failed to load image`. `webp_proxy.py`
transcodes `data:image/webp` → PNG in-flight (llama.cpp's own web UI does the
same). **Text-only models don't need it** — point GJC straight at `:8080`.

---

## Portability

Nothing about one machine is baked in. `scripts/common.sh` discovers the
environment at run time, and every probe has an override you can set in
`model.env` for a layout it guesses wrong:

| Discovered | How | Override |
|------------|-----|----------|
| conda | `miniforge3`, `mambaforge`, `miniconda3`, `anaconda3`, `/opt/conda`, `$CONDA_EXE`, `conda info --base` | `CONDA_SH` |
| python | `$PYTHON` → `python3` → `python`, resolved to an **absolute** path after activating `CONDA_ENV` | `PYTHON` |
| CUDA toolkit | `nvcc` on `PATH` → newest `/usr/local/cuda-*` **that the driver can actually run** → `$CONDA_PREFIX` | `CUDA_HOME` |
| GPU arch | `nvidia-smi --query-gpu=compute_cap` (e.g. `8.0`,`9.0` → `80;90`), else `native` | `CUDA_ARCHS` |
| llama.cpp | `$LLAMA_SRC/build/bin/llama-server` | `LLAMA_SRC`, `LLAMA_BIN` |
| HF downloader | `hf` → `huggingface-cli` → `huggingface_hub` python API | — |

Two deliberate design rules:

- **Missing dependencies fail loudly.** If the resolved python can't import
  `aiohttp`/`Pillow`, `start.sh` stops and prints the exact `pip install` line.
  Silently falling back to an interpreter without them produces a proxy that
  dies with an unrelated-looking error.
- **Kills are scoped and never suicidal.** Processes are matched by `--alias` or
  listening port, and this process plus its ancestors are excluded — a plain
  `pkill -f webp_proxy.py` kills the shell that launched it, because that
  shell's own command line contains the pattern.

Before a multi-minute model load, `start.sh` also warns if no GPU is visible,
if `GPU` exceeds the device count, or if the model file is larger than the
roomiest card's free VRAM.

> One caveat it can't solve for you: on multi-GPU boxes `CUDA_VISIBLE_DEVICES`
> ordering need not match `nvidia-smi`'s. Confirm placement with
> `nvidia-smi --query-compute-apps=pid,used_memory --format=csv`.

---

## 8. Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `400 Failed to load image` in GJC | WebP. Run the proxy; point `baseUrl` at `:8081`. |
| Model runs on **CPU** (slow, ~0 VRAM) | CUDA backend not built. Rebuild with `-DGGML_CUDA=ON`; check `ldd .../llama-server` resolves `libcudart.so.12`. |
| `unknown architecture` / won't load | `llama.cpp` too old. `cd ~/llama.cpp && git pull` then re-run `build-llama.sh`. |
| Answer **empty**, `finish_reason: length` | Thinking ate the tokens. Raise `MAXTOKENS` / `CTX_SIZE`; answer is in `content`, reasoning in `reasoning_content`. |
| GJC ignores your provider | It relies on cached auto-discovery. Use the explicit `providers:` entry (§5) and select with `--model <ALIAS>-local/<ALIAS>`. |
| Wrong **physical GPU** | On some boxes `CUDA_VISIBLE_DEVICES` order ≠ `nvidia-smi` index. Check `nvidia-smi --query-compute-apps=pid,used_memory --format=csv`, adjust `GPU`. |
| Proxy dies on restart | Don't `pkill -f webp_proxy.py` from the shell that launched it. Use `stop.sh` / `start.sh`. |

---

## 9. Notes on "thinking"

`llama.cpp` thinking is **on/unrestricted by default** (`--reasoning-budget -1`),
not a graded dial. The real lever against truncated reasoning is a big single
slot (`--parallel 1 --ctx-size ...`). GJC's `--thinking` level and `reasoning:
true` control how the trace is **surfaced**, not whether a non-reasoning model
reasons. Local models stream the **raw** chain-of-thought; hosted models (Opus,
GPT-5) show a **summarized** reasoning trace — raw CoT is more verbose but more
interpretable.

---

## License

MIT — see [LICENSE](LICENSE).
