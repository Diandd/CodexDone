#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/artifacts/build/DerivedData"
APP_BINARY="$DERIVED_DATA_PATH/Build/Products/Debug/CodexDone.app/Contents/MacOS/CodexDone"

if [[ "${1:-}" != "--audio" || -z "${2:-}" ]]; then
  printf 'usage: %s --audio /absolute/path/to/test.{aac,aif,aiff,caf,m4a,mp3,wav}\n' "$0" >&2
  exit 2
fi

AUDIO_PATH="$2"
shopt -s nocasematch
if [[ "$AUDIO_PATH" != /* || ! -f "$AUDIO_PATH" || ! "$AUDIO_PATH" =~ \.(aac|aif|aiff|caf|m4a|mp3|wav)$ ]]; then
  printf 'The audio path must be an existing absolute path with a supported extension.\n' >&2
  exit 2
fi
shopt -u nocasematch

"$ROOT_DIR/script/build_and_run.sh" --build-only

SMOKE_DIR="$(mktemp -d /tmp/codexdone-offscreen-audio.XXXXXX)"
REPORT_PATH="$SMOKE_DIR/report.json"
APP_LOG_PATH="$SMOKE_DIR/app.log"
cleanup() {
  pkill -x CodexDone >/dev/null 2>&1 || true
  if [[ "$SMOKE_DIR" == /tmp/codexdone-offscreen-audio.* ]]; then
    rm -rf "$SMOKE_DIR"
  fi
}
trap cleanup EXIT

pkill -x CodexDone >/dev/null 2>&1 || true
"$APP_BINARY" -ApplePersistenceIgnoreState YES \
  --offscreen-audio-smoke "$AUDIO_PATH" "$REPORT_PATH" \
  >"$APP_LOG_PATH" 2>&1 &
APP_PID=$!

for _ in {1..80}; do
  if [[ -s "$REPORT_PATH" ]]; then
    break
  fi
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if [[ ! -s "$REPORT_PATH" ]]; then
  printf 'CodexDone did not produce an offscreen audio report.\n' >&2
  sed -n '1,120p' "$APP_LOG_PATH" >&2
  exit 1
fi

jq -e '
  .version == 1 and
  .passed == true and
  .defaultPlayback == true and
  .customImport == true and
  .customPlayback == true and
  .failure == null
' "$REPORT_PATH" >/dev/null
printf 'Offscreen system sound and imported audio playback passed.\n'
