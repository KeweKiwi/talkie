#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="talkie"
BUNDLE_ID="co.kewekiwi.talkie"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
# Ask a running app to quit so recordings are saved before rebuilding.
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -TERM -x "$APP_NAME" || true
  for ((i=0; i<120; i++)); do
    if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "talkie is still saving data. Stop recording or cancel processing, then run again." >&2
    exit 1
  fi
fi
swift build --product "$APP_NAME"
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/asr-manifest.json "$APP_BUNDLE/Contents/Resources/"
if [[ -d docs/licenses ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/licenses"
  for license_file in docs/licenses/*; do
    install -m 644 "$license_file" "$APP_BUNDLE/Contents/Resources/licenses/$(basename "$license_file")"
  done
fi
# Prefer the single existing local Apple Development identity so Accessibility
# trust survives rebuilds. Never create/import keys or alter global signing.
SIGNING_IDENTITY="${TALKIE_SIGNING_IDENTITY:--}"
if [[ -z "${TALKIE_SIGNING_IDENTITY:-}" ]]; then
  AVAILABLE_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ {print $2}')"
  if [[ "$AVAILABLE_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then SIGNING_IDENTITY="$AVAILABLE_IDENTITY"; fi
fi
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "$BUNDLE_ID" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --build-only|build-only) echo "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 1; pgrep -x "$APP_NAME" >/dev/null; echo "talkie launched" ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
