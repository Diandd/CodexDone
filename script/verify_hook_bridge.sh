#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/artifacts/build/DerivedData/Build/Products/Debug/CodexDone.app}"
HELPER="$APP_BUNDLE/Contents/Helpers/CodexDoneHookBridge"
SMOKE_DIR="$(mktemp -d /tmp/codexdone-hookbridge.XXXXXX)"
SPOOL_DIR="$SMOKE_DIR/spool"
SOCKET_PATH="$SMOKE_DIR/missing.sock"

cleanup() {
  if [[ "$SMOKE_DIR" == /tmp/codexdone-hookbridge.* ]]; then
    rm -rf "$SMOKE_DIR"
  fi
}
trap cleanup EXIT

if [[ ! -x "$HELPER" ]]; then
  printf 'Hook Bridge is missing: %s\n' "$HELPER" >&2
  exit 1
fi

prompt_output="$({
  printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-session","turn_id":"smoke-turn","cwd":"/tmp/SafeProject","prompt":"## My request:\n验证菜单主题","transcript_path":"/private/ignored.jsonl"}'
} | CODEXDONE_BRIDGE_SOCKET_PATH="$SOCKET_PATH" CODEXDONE_BRIDGE_SPOOL_DIR="$SPOOL_DIR" CODEXDONE_BRIDGE_DISABLE_WAKE=1 "$HELPER")"

if [[ -n "$prompt_output" ]]; then
  printf 'UserPromptSubmit wrote unexpected stdout.\n' >&2
  exit 1
fi

stop_output="$({
  printf '%s' '{"hook_event_name":"Stop","session_id":"smoke-session","turn_id":"smoke-turn","cwd":"/tmp/SafeProject","last_assistant_message":"已生成桥接回复预览。","transcript_path":"/private/ignored.jsonl"}'
} | CODEXDONE_BRIDGE_SOCKET_PATH="$SOCKET_PATH" CODEXDONE_BRIDGE_SPOOL_DIR="$SPOOL_DIR" CODEXDONE_BRIDGE_DISABLE_WAKE=1 "$HELPER")"

if [[ "$stop_output" != '{"continue":true}' ]]; then
  printf 'Stop stdout contract failed: %s\n' "$stop_output" >&2
  exit 1
fi

event_count="$(find "$SPOOL_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ "$event_count" != "2" ]]; then
  printf 'Expected 2 spooled events, found %s.\n' "$event_count" >&2
  exit 1
fi

if [[ "$(stat -f '%Lp' "$SPOOL_DIR")" != "700" ]]; then
  printf 'Spool directory permissions are not 0700.\n' >&2
  exit 1
fi

while IFS= read -r event_file; do
  if [[ "$(stat -f '%Lp' "$event_file")" != "600" ]]; then
    printf 'Spool event permissions are not 0600.\n' >&2
    exit 1
  fi
done < <(find "$SPOOL_DIR" -maxdepth 1 -type f -name '*.json')

if find "$SPOOL_DIR" -maxdepth 1 -type f -name '*.tmp' -print -quit | grep -q .; then
  printf 'Spool left a temporary file behind.\n' >&2
  exit 1
fi

if rg -n '"prompt"|last_assistant_message|transcript|tool_name|tool_input|private command|private reason' "$SPOOL_DIR" >/dev/null; then
  printf 'Hook Bridge persisted a forbidden field.\n' >&2
  exit 1
fi

if ! rg -q '"conversationTitle"' "$SPOOL_DIR" || ! rg -q '"replyPreview"' "$SPOOL_DIR"; then
  printf 'Hook Bridge did not persist the bounded display fields.\n' >&2
  exit 1
fi

printf 'Hook Bridge stdout, fallback, bounded display data, and privacy checks passed.\n'
