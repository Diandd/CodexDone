#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'usage: %s /absolute/path/to/CodexDone.app /absolute/path/to/output.dmg [volume-name]\n' "$0" >&2
  exit 2
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
VOLUME_NAME="${3:-CodexDone}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKGROUND_GENERATOR="$ROOT_DIR/script/generate_dmg_background.swift"
LAYOUT_SCRIPT="$ROOT_DIR/script/layout_dmg.applescript"
WORK_DIR="$(mktemp -d /tmp/codexdone-dmg.XXXXXX)"
STAGING_DIR="$WORK_DIR/staging"
READ_WRITE_DMG="$WORK_DIR/read-write.dmg"
MOUNT_POINT=""

fail() {
  printf 'create_dmg failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  if [[ "$WORK_DIR" == /tmp/codexdone-dmg.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

[[ "$APP_PATH" == /* && -d "$APP_PATH" ]] || fail "app path must be an absolute .app directory"
[[ "$APP_PATH" == *.app ]] || fail "app path must end in .app"
[[ "$OUTPUT_DMG" == /* && "$OUTPUT_DMG" == *.dmg ]] \
  || fail "output path must be an absolute .dmg path"
[[ -f "$BACKGROUND_GENERATOR" && -f "$LAYOUT_SCRIPT" ]] \
  || fail "DMG design inputs are missing"

if [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  DEVELOPER_ROOT="/Applications/Xcode-beta.app/Contents/Developer"
else
  DEVELOPER_ROOT="$(/usr/bin/xcode-select -p)"
fi
export DEVELOPER_DIR="$DEVELOPER_ROOT"

mkdir -p "$STAGING_DIR/.background" "$(dirname "$OUTPUT_DMG")"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/CodexDone.app"
ln -s /Applications "$STAGING_DIR/Applications"
SWIFT_MODULECACHE_PATH="$WORK_DIR/swift-module-cache" \
CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache" \
  /usr/bin/xcrun swift "$BACKGROUND_GENERATOR" \
  "$STAGING_DIR/.background/installer-background.png"

APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
if [[ -f "$APP_ICON" ]]; then
  /usr/bin/ditto "$APP_ICON" "$STAGING_DIR/.VolumeIcon.icns"
fi

rm -f "$OUTPUT_DMG" "$READ_WRITE_DMG"
/usr/bin/hdiutil create \
  -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDRW \
  "$READ_WRITE_DMG"

ATTACH_OUTPUT="$(
  /usr/bin/hdiutil attach "$READ_WRITE_DMG" -readwrite -noverify -noautoopen
)"
MOUNT_POINT="$(
  printf '%s\n' "$ATTACH_OUTPUT" \
    | /usr/bin/awk -F '\t' '$3 ~ /^\// { print $3; exit }'
)"
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || fail "unable to locate mounted DMG"

/usr/bin/touch "$MOUNT_POINT/.metadata_never_index"
if [[ -f "$MOUNT_POINT/.VolumeIcon.icns" ]]; then
  /usr/bin/xcrun SetFile -a C "$MOUNT_POINT"
  /usr/bin/xcrun SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns"
fi
/usr/bin/xcrun SetFile -a V "$MOUNT_POINT/.background"

/usr/bin/osascript "$LAYOUT_SCRIPT" "$VOLUME_NAME"
/bin/sync
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

/usr/bin/hdiutil convert \
  "$READ_WRITE_DMG" \
  -quiet \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG"
/usr/bin/hdiutil verify "$OUTPUT_DMG"

VERIFY_ATTACH_OUTPUT="$(
  /usr/bin/hdiutil attach "$OUTPUT_DMG" -readonly -noverify -nobrowse
)"
MOUNT_POINT="$(
  printf '%s\n' "$VERIFY_ATTACH_OUTPUT" \
    | /usr/bin/awk -F '\t' '$3 ~ /^\// { print $3; exit }'
)"
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] \
  || fail "unable to mount the completed DMG for verification"
[[ -d "$MOUNT_POINT/CodexDone.app" ]] || fail "completed DMG is missing CodexDone.app"
[[ -L "$MOUNT_POINT/Applications" ]] || fail "completed DMG is missing Applications link"
[[ -f "$MOUNT_POINT/.background/installer-background.png" ]] \
  || fail "completed DMG is missing installer background"
[[ -f "$MOUNT_POINT/.DS_Store" ]] || fail "completed DMG is missing Finder layout"
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

printf 'DMG created: %s\n' "$OUTPUT_DMG"
