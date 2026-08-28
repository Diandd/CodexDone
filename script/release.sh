#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexDone"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexDone.xcodeproj"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_release_bundle.sh"
MODE="${1:---archive-only}"
TEAM_ID="${CODEXDONE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${CODEXDONE_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${CODEXDONE_NOTARY_PROFILE:-}"
REAL_DESKTOP_SMOKE="${CODEXDONE_REAL_DESKTOP_SMOKE:-}"

fail() {
  printf 'release failed: %s\n' "$1" >&2
  exit 1
}

[[ "$MODE" == "--archive-only" || "$MODE" == "--notarize" ]] \
  || fail "usage: $0 [--archive-only|--notarize]"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "set CODEXDONE_DEVELOPMENT_TEAM to a 10-character Team ID"
if [[ "$MODE" == "--notarize" && -z "$NOTARY_PROFILE" ]]; then
  fail "set CODEXDONE_NOTARY_PROFILE to a notarytool keychain profile"
fi
[[ -f "$ROOT_DIR/LICENSE" || -f "$ROOT_DIR/LICENSE.md" || -f "$ROOT_DIR/LICENSE.txt" ]] \
  || fail "choose and add a license before producing a public release"
if grep -Eq 'licenseDisplayName[^=]*=[[:space:]]*(nil|"")' \
  "$ROOT_DIR/CodexDone/Support/ProductConfiguration.swift"; then
  fail "set ProductConfiguration.licenseDisplayName before release"
fi
[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]] \
  || fail "commit all tracked release changes before archiving"
UNTRACKED_RELEASE_INPUTS="$(
  git -C "$ROOT_DIR" ls-files --others --exclude-standard -- \
    CodexDone.xcodeproj CodexDone CodexDoneHookBridge CodexDoneTests \
    CodexDoneUITests script LICENSE LICENSE.md LICENSE.txt
)"
[[ -z "$UNTRACKED_RELEASE_INPUTS" ]] \
  || fail "release inputs must be committed before archiving: $UNTRACKED_RELEASE_INPUTS"
[[ "$REAL_DESKTOP_SMOKE" == "PASS" ]] \
  || fail "complete the real Codex Desktop smoke test, then set CODEXDONE_REAL_DESKTOP_SMOKE=PASS"

if [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
  export DEVELOPER_DIR="$(xcode-select -p)"
fi

"$ROOT_DIR/script/test.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE_ROOT="$ROOT_DIR/artifacts/release/$STAMP"
ARCHIVE_PATH="$RELEASE_ROOT/$APP_NAME.xcarchive"
EXPORT_PATH="$RELEASE_ROOT/export"
EXPORT_OPTIONS="$RELEASE_ROOT/ExportOptions.plist"
mkdir -p "$RELEASE_ROOT" "$EXPORT_PATH"

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS"

xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" DEVELOPMENT_TEAM="$TEAM_ID" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
"$VERIFY_SCRIPT" --run-hook-health-check --expected-team "$TEAM_ID" "$APP_PATH"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
STEM="$APP_NAME-$VERSION-$BUILD-macOS"

if [[ "$MODE" == "--notarize" ]]; then
  UPLOAD_ZIP="$RELEASE_ROOT/$STEM-notary-upload.zip"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_PATH" "$UPLOAD_ZIP"
  xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$RELEASE_ROOT/notary-result.json"
  [[ "$(plutil -extract status raw "$RELEASE_ROOT/notary-result.json")" == "Accepted" ]] \
    || fail "notarization was not accepted"
  xcrun stapler staple "$APP_PATH"
  "$VERIFY_SCRIPT" --require-notarized --expected-team "$TEAM_ID" "$APP_PATH"
  FINAL_ZIP="$RELEASE_ROOT/$STEM.zip"
else
  FINAL_ZIP="$RELEASE_ROOT/$STEM-UNNOTARIZED.zip"
fi

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_PATH" "$FINAL_ZIP"
(
  cd "$RELEASE_ROOT"
  shasum -a 256 "$(basename "$FINAL_ZIP")" > SHA256SUMS.txt
)
printf 'Release artifacts created in %s\n' "$RELEASE_ROOT"
if [[ "$MODE" == "--archive-only" ]]; then
  printf 'Archive-only output is not notarized and must not be published.\n'
fi
