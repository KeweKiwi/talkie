#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT_DIR/.local-data/ollama-runtime/ollama"
if [[ ! -x "$RUNTIME" ]]; then RUNTIME="$(command -v ollama)"; fi
export OLLAMA_HOST=127.0.0.1:11434
"$RUNTIME" pull qwen3.5:9b-q4_K_M
"$RUNTIME" pull gemma4:e4b-it-qat
