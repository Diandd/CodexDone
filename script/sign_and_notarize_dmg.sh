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
CREATE_DMG_SCRIPT="$ROOT_DIR/script/create_dmg.sh"
VERIFY_APP_SCRIPT="$ROOT_DIR/script/verify_release_bundle.sh"
TEAM_ID="${CODEXDONE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${CODEXDONE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${CODEXDONE_NOTARY_PROFILE:-}"
DMG_IDENTIFIER="${CODEXDONE_DMG_IDENTIFIER:-com.dianstudios.codexdone.dmg}"
WORK_DIR="$(mktemp -d /tmp/codexdone-signing.XXXXXX)"
SIGNED_APP="$WORK_DIR/CodexDone.app"
HOOK_BRIDGE="$SIGNED_APP/Contents/Helpers/CodexDoneHookBridge"
NOTARY_RESULT="${OUTPUT_DMG%.dmg}.notary.json"
CHECKSUM_PATH="$OUTPUT_DMG.sha256"

fail() {
  printf 'sign_and_notarize_dmg failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ "$WORK_DIR" == /tmp/codexdone-signing.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

[[ "$APP_PATH" == /* && -d "$APP_PATH" && ! -L "$APP_PATH" ]] \
  || fail "app path must be an absolute, non-symlink .app directory"
[[ "$APP_PATH" == *.app ]] || fail "app path must end in .app"
[[ "$OUTPUT_DMG" == /* && "$OUTPUT_DMG" == *.dmg ]] \
  || fail "output path must be an absolute .dmg path"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "set CODEXDONE_DEVELOPMENT_TEAM to the signing team's 10-character Team ID"
[[ -n "$SIGNING_IDENTITY" ]] \
  || fail "set CODEXDONE_SIGNING_IDENTITY to the full Developer ID Application identity"
[[ -n "$NOTARY_PROFILE" ]] \
  || fail "set CODEXDONE_NOTARY_PROFILE to a notarytool keychain profile"
[[ -x "$CREATE_DMG_SCRIPT" && -x "$VERIFY_APP_SCRIPT" ]] \
  || fail "the signing handoff tools are incomplete"

AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
[[ "$AVAILABLE_IDENTITIES" == *"$SIGNING_IDENTITY"* ]] \
  || fail "the requested Developer ID Application identity is not available in this keychain"

rm -f "$NOTARY_RESULT" "$CHECKSUM_PATH"

# Incoming apps transferred through a browser or chat client can carry Gatekeeper
# quarantine. Work only on a quarantine-free temporary copy; never mutate the input.
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$SIGNED_APP"
/usr/bin/xattr -dr com.apple.quarantine "$SIGNED_APP" 2>/dev/null || true
REMAINING_QUARANTINE="$(
  /usr/bin/xattr -lr "$SIGNED_APP" 2>/dev/null \
    | /usr/bin/grep -F 'com.apple.quarantine:' \
    || true
)"
[[ -z "$REMAINING_QUARANTINE" ]] \
  || fail "download quarantine could not be removed from the temporary app copy"
[[ -x "$HOOK_BRIDGE" ]] || fail "the embedded CodexDoneHookBridge is missing"

# Sign the nested executable first, then seal the outer app bundle.
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --identifier com.dianstudios.codexdone.hookbridge \
  --sign "$SIGNING_IDENTITY" \
  "$HOOK_BRIDGE"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$SIGNED_APP"

# Pre-notarization verification is deliberately static. Launching a transferred
# app or helper here would invoke Gatekeeper before Apple can notarize the DMG.
"$VERIFY_APP_SCRIPT" --expected-team "$TEAM_ID" "$SIGNED_APP"
"$CREATE_DMG_SCRIPT" "$SIGNED_APP" "$OUTPUT_DMG" "$VOLUME_NAME"

# A DMG uses Developer ID Application, not Developer ID Installer.
/usr/bin/codesign \
  --force \
  --timestamp \
  --identifier "$DMG_IDENTIFIER" \
  --sign "$SIGNING_IDENTITY" \
  "$OUTPUT_DMG"
/usr/bin/codesign --verify --verbose=2 "$OUTPUT_DMG"

/usr/bin/xcrun notarytool submit "$OUTPUT_DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_RESULT"
NOTARY_STATUS="$(/usr/bin/plutil -extract status raw "$NOTARY_RESULT" 2>/dev/null || true)"
[[ "$NOTARY_STATUS" == "Accepted" ]] \
  || fail "Apple notarization was not accepted; inspect $NOTARY_RESULT"

/usr/bin/xcrun stapler staple "$OUTPUT_DMG"
/usr/bin/xcrun stapler validate "$OUTPUT_DMG"
/usr/sbin/spctl -a -t open -vvv \
  --context context:primary-signature \
  "$OUTPUT_DMG"

DMG_HASH="$(/usr/bin/shasum -a 256 "$OUTPUT_DMG" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$DMG_HASH" "$(basename "$OUTPUT_DMG")" > "$CHECKSUM_PATH"

printf 'Signed, notarized, and stapled DMG: %s\n' "$OUTPUT_DMG"
printf 'Notary result: %s\n' "$NOTARY_RESULT"
printf 'SHA-256: %s\n' "$CHECKSUM_PATH"
