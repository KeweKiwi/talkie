#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT_DIR/.local-data/ollama-runtime/ollama"
if [[ ! -x "$RUNTIME" ]]; then RUNTIME="$(command -v ollama)"; fi
# No edits to existing server/global configuration. A occupied port fails normally.
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_NO_CLOUD=1
export OLLAMA_MAX_LOADED_MODELS=1
exec "$RUNTIME" serve
