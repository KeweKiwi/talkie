#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT_DIR/.local-data/offline-run-$(date +%s)"
mkdir -p "$RUN_DIR"
ln -s "$HOME/Library/Application Support/talkie/models" "$RUN_DIR/models"
APP_BINARY="$ROOT_DIR/dist/talkie.app/Contents/MacOS/talkie"
[[ -x "$APP_BINARY" ]] || { echo 'Build the app bundle first.' >&2; exit 1; }
# Explicit diagnostic only. Ordinary launches use open on the app bundle.
TALKIE_DATA_ROOT="$RUN_DIR" /usr/bin/time -l /usr/bin/sandbox-exec \
  -p '(version 1)(allow default)(deny network*)' \
  "$APP_BINARY" --self-test --fixture-root "$ROOT_DIR/.local-data/asr-fixtures" \
  --report "$RUN_DIR/report.json" --off-pipeline-test --exit-after-test
python3 - "$RUN_DIR/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert not any(k.endswith('_error') for k in r), r
assert len(r['asr'])==6 and r['silence_detected'] and r['silence_segments']==0
assert r['preferences_restart']
p=r['cleanup_off_pipeline']
assert p['editor_calls']==0 and p['raw_matches_asr'] and p['export_contains_full_raw']
assert r['long_writer_fixture']['all_chunks_readable_mono_16k']
assert r['crash_recovery']['status']=='incomplete'
print('Offline ASR, Cleanup OFF, complete export, writer fixture and recovery passed.')
PY
echo "$RUN_DIR/report.json"
