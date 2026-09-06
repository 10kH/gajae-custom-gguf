#!/usr/bin/env bash
# Emit the GJC provider block for THIS model, generated from model.env.
# Merge the output into ~/.gjc/agent/models.yml (don't duplicate the top-level
# `providers:` key if it already exists).
#   ./scripts/render-gjc-config.sh                 # print to stdout
#   ./scripts/render-gjc-config.sh >> ~/.gjc/agent/models.yml   # append (mind duplicate keys!)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${MODEL_ENV:-$ROOT/model.env}"

if [ -n "${MMPROJ_FILE:-}" ]; then
  BASEURL="http://127.0.0.1:${PPORT:-8081}/v1"   # via webp proxy
  INPUT="[text, image]"
else
  BASEURL="http://127.0.0.1:${SPORT:-8080}/v1"   # direct
  INPUT="[text]"
fi
REASONING="${REASONING:-true}"

cat <<YAML
providers:
  ${ALIAS}-local:
    baseUrl: ${BASEURL}
    api: openai-completions
    auth: none
    models:
      - id: ${ALIAS}
        name: ${ALIAS} (local)
        input: ${INPUT}
        reasoning: ${REASONING}
YAML

if [ "$REASONING" = "true" ]; then
cat <<'YAML'
        thinking:
          minLevel: low
          maxLevel: xhigh
          mode: effort
          defaultLevel: high
          levels: [low, medium, high, xhigh]
YAML
fi

cat <<YAML
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        contextWindow: ${CTX_SIZE:-65536}
        maxTokens: ${MAXTOKENS:-32768}
YAML
