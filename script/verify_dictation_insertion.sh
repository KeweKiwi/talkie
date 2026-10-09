#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT_DIR/.local-data/insertion-run-$(date +%s)"
MODE="${1:-off}"
[[ "$MODE" == off || "$MODE" == on ]] || { echo 'usage: verify_dictation_insertion.sh [off|on] [focus-delay-seconds]' >&2; exit 2; }
pgrep -x talkie >/dev/null && { echo 'Quit talkie before launching this isolated diagnostic.' >&2; exit 1; }
mkdir -p "$RUN_DIR"
ln -s "$HOME/Library/Application Support/talkie/models" "$RUN_DIR/models"
ARGS=(--self-test --dictation-insertion-test --fixture-root "$ROOT_DIR/.local-data/asr-fixtures" --report "$RUN_DIR/report.json" --focus-delay "${2:-20}" --exit-after-test)
[[ "$MODE" == on ]] && ARGS+=(--cleanup-on)
# After launch, focus a disposable external field during the stated delay.
# Uses the signed bundle and production ASR/cleanup/insertion services.
/usr/bin/open -g -n -W --env "TALKIE_DATA_ROOT=$RUN_DIR" "$ROOT_DIR/dist/talkie.app" --args "${ARGS[@]}"
python3 - "$RUN_DIR/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert 'insertion_error' not in r, r
p=r['dictation_insertion']
assert p['raw_fixture'] and p['output_fixture'] and p['archive_count_unchanged'] and p['metrics']['temporaryAudioRemoved'] and p['history_selection_unchanged'], r
assert p['editor_calls']==int(p['cleanup_on']), r
print(json.dumps(r,ensure_ascii=False,indent=2))
assert p['metrics']['inserted'], 'Delivery not confirmed; inspect the report and target.'
PY
