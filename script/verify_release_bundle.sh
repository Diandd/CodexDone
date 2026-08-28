#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexDone"
EXPECTED_BUNDLE_ID="com.dianstudios.codexdone"
EXPECTED_TEAM_ID=""
REQUIRE_NOTARIZED=0
RUN_HOOK_HEALTH_CHECK=0

fail() {
  printf 'release verification failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s [--require-notarized] [--run-hook-health-check] [--expected-team TEAMID] /absolute/path/to/CodexDone.app\n' "$0" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarized)
      REQUIRE_NOTARIZED=1
      shift
      ;;
    --run-hook-health-check)
      RUN_HOOK_HEALTH_CHECK=1
      shift
      ;;
    --expected-team)
      [[ $# -ge 2 ]] || usage
      EXPECTED_TEAM_ID="$2"
      shift 2
      ;;
    -*) usage ;;
    *) break ;;
  esac
done

[[ $# -eq 1 ]] || usage
[[ -z "$EXPECTED_TEAM_ID" || "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "--expected-team must be a 10-character Team ID"
APP_PATH="$1"
[[ "$APP_PATH" == /* ]] || fail "the app path must be absolute"
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] || fail "the app bundle is missing or unsafe"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"
HOOK_BRIDGE="$APP_PATH/Contents/Helpers/CodexDoneHookBridge"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
[[ -x "$APP_BINARY" ]] || fail "the main executable is missing"
[[ -x "$HOOK_BRIDGE" ]] || fail "the embedded Hook Bridge is missing"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle identifier"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)" ]] \
  || fail "the marketing version is missing"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)" ]] \
  || fail "the build version is missing"
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || fail "the compiled app icon is missing"

if find "$APP_PATH/Contents" -type l -print -quit | grep -q .; then
  fail "symbolic links are not permitted in the release bundle"
fi
if find "$APP_PATH/Contents" -type f -name codex -print -quit | grep -q .; then
  fail "the release bundle must not embed Codex"
fi
if find "$APP_PATH/Contents" -path '*/.codexdone-archive/*' -print -quit | grep -q .; then
  fail "the local legacy archive leaked into the release bundle"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$RUN_HOOK_HEALTH_CHECK" -eq 1 ]]; then
  "$HOOK_BRIDGE" --health-check || fail "the embedded Hook Bridge health check failed"
fi

SCAN_DIR="$(mktemp -d /tmp/codexdone-release-scan.XXXXXX)"
cleanup() {
  if [[ "$SCAN_DIR" == /tmp/codexdone-release-scan.* ]]; then
    rm -rf "$SCAN_DIR"
  fi
}
trap cleanup EXIT

for binary in "$APP_BINARY" "$HOOK_BRIDGE"; do
  SCAN_FILE="$SCAN_DIR/$(basename "$binary").strings"
  /usr/bin/strings "$binary" > "$SCAN_FILE" \
    || fail "a Release binary could not be scanned"
  if grep -F -e '--ui-test' -e '--offscreen-audio-smoke' \
    -e '--install-hooks-smoke' "$SCAN_FILE" >/dev/null; then
    fail "Debug-only smoke code is present in Release"
  fi
  if grep -F 'CODEXDONE_BRIDGE_' "$SCAN_FILE" >/dev/null; then
    fail "Debug-only Hook Bridge environment overrides are present in Release"
  fi
done

if [[ -n "$EXPECTED_TEAM_ID" ]]; then
  for code_path in "$APP_PATH" "$HOOK_BRIDGE"; do
    SIGNING_DETAILS="$(/usr/bin/codesign -dvvv "$code_path" 2>&1)"
    printf '%s\n' "$SIGNING_DETAILS" | grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" \
      || fail "a signature has an unexpected Team ID"
    printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application:' \
      || fail "a signature is not Developer ID Application"
    printf '%s\n' "$SIGNING_DETAILS" | grep -Eq 'flags=.*runtime' \
      || fail "Hardened Runtime is missing"
    printf '%s\n' "$SIGNING_DETAILS" | grep -Eq '^Timestamp=.+$' \
      || fail "a trusted signing timestamp is missing"
  done
fi

if [[ "$REQUIRE_NOTARIZED" -eq 1 ]]; then
  /usr/bin/xcrun stapler validate "$APP_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

if [[ "$RUN_HOOK_HEALTH_CHECK" -eq 1 ]]; then
  printf 'Release bundle structure, Hook Bridge runtime health, privacy boundaries, and signatures passed.\n'
else
  printf 'Release bundle structure, embedded Hook Bridge, privacy boundaries, and signatures passed without launching the app or helper.\n'
fi
