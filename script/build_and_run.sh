#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexDone"
BUNDLE_ID="com.dianstudios.codexdone"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexDone.xcodeproj"
DERIVED_DATA_PATH="$ROOT_DIR/artifacts/build/DerivedData"
CONFIGURATION="Debug"

resolve_developer_dir() {
  local beta_xcode="/Applications/Xcode-beta.app/Contents/Developer"
  local selected_dir

  if [[ -x "$beta_xcode/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "$beta_xcode"
    return
  fi

  selected_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$selected_dir" && -x "$selected_dir/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "$selected_dir"
    return
  fi

  printf 'CodexDone requires a full Xcode 27 installation.\n' >&2
  exit 1
}

export DEVELOPER_DIR="$(resolve_developer_dir)"
mkdir -p "$DERIVED_DATA_PATH"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HOOK_BRIDGE="$APP_BUNDLE/Contents/Helpers/CodexDoneHookBridge"

if [[ ! -x "$APP_BINARY" ]]; then
  printf 'Built application is missing: %s\n' "$APP_BINARY" >&2
  exit 1
fi
if [[ ! -x "$HOOK_BRIDGE" ]]; then
  printf 'Bundled Hook Bridge is missing: %s\n' "$HOOK_BRIDGE" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  local attempt
  for attempt in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      printf '%s is running from %s\n' "$APP_NAME" "$APP_BUNDLE"
      return
    fi
    sleep 0.25
  done

  printf '%s did not remain running after launch.\n' "$APP_NAME" >&2
  exit 1
}

case "$MODE" in
  --build-only|build-only)
    printf '%s and Hook Bridge built successfully at %s\n' "$APP_NAME" "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
  *)
    printf 'usage: %s [run|--build-only|--debug|--logs|--telemetry|--verify]\n' "$0" >&2
    exit 2
    ;;
esac
