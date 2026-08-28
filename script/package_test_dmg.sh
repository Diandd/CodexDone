#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexDone"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexDone.xcodeproj"
DERIVED_DATA="$ROOT_DIR/artifacts/build/DerivedData"
RELEASE_DIR="$ROOT_DIR/artifacts/release"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_release_bundle.sh"
CREATE_DMG_SCRIPT="$ROOT_DIR/script/create_dmg.sh"

if [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  XCODEBUILD="/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild"
else
  XCODEBUILD="$(/usr/bin/xcrun --find xcodebuild)"
fi

"$XCODEBUILD" -quiet \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
"$VERIFY_SCRIPT" "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
STEM="$APP_NAME-$VERSION-$BUILD-macOS27-arm64-TEST-UNNOTARIZED"
DMG_PATH="$RELEASE_DIR/$STEM.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
PARTIAL_DMG="$RELEASE_DIR/.$STEM.partial.dmg"

cleanup() {
  rm -f "$PARTIAL_DMG"
}
trap cleanup EXIT

mkdir -p "$RELEASE_DIR"
rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$PARTIAL_DMG"
"$CREATE_DMG_SCRIPT" \
  "$APP_PATH" \
  "$PARTIAL_DMG" \
  "$APP_NAME $VERSION-$BUILD Test"
mv "$PARTIAL_DMG" "$DMG_PATH"
(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf 'Test DMG: %s\n' "$DMG_PATH"
printf 'SHA-256: '
/usr/bin/awk '{print $1}' "$CHECKSUM_PATH"
printf 'This artifact is ad-hoc signed and not notarized. It is not a public release.\n'
