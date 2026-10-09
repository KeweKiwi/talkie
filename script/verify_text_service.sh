#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT_DIR/.local-data/text-run-$(date +%s)"
mkdir -p "$RUN_DIR"
APP_BINARY="$ROOT_DIR/dist/talkie.app/Contents/MacOS/talkie"
[[ -x "$APP_BINARY" ]] || { echo 'Build the app bundle first.' >&2; exit 1; }
# The pinned server must already be running. Only loopback inference is allowed.
TALKIE_DATA_ROOT="$RUN_DIR" /usr/bin/time -l /usr/bin/sandbox-exec \
  -p '(version 1)(allow default)(deny network*)(allow network-outbound (remote ip "localhost:11434"))' \
  "$APP_BINARY" --self-test --text-service-test \
  --fixture-root "$ROOT_DIR/.local-data/asr-fixtures" \
  --report "$RUN_DIR/report.json" --exit-after-test
python3 - "$RUN_DIR/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert 'text_service_error' not in r, r
assert r['cleanup_calls']==1 and 'but the admin page' in r['cleanup']['output']
assert r['summary']['promptVersion']=='grounded-summary-v2'
print('Native local text client and summary evidence validation passed with external networking denied.')
PY
echo "$RUN_DIR/report.json"
