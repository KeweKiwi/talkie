#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .local-data/ollama-runtime
curl -fL --retry 2 'https://github.com/ollama/ollama/releases/download/v0.40.1/ollama-darwin.tgz' -o .local-data/ollama-darwin.tgz
printf '%s  %s\n' '66e1587711f3a06315b23782ba74897001da6c8b8edf6c0371f7533015a076dd' '.local-data/ollama-darwin.tgz' | shasum -a 256 -c -
tar -xzf .local-data/ollama-darwin.tgz -C .local-data/ollama-runtime
printf 'Project-local Ollama 0.40.1 ready. Run ./script/start_ollama.sh\n'
