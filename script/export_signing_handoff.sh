#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s /absolute/path/to/CodexDone-DMG-Handoff.zip\n' "$0" >&2
  exit 2
fi

OUTPUT_ZIP="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/codexdone-handoff.XXXXXX)"
KIT_DIR="$WORK_DIR/CodexDone-DMG-Handoff"

fail() {
  printf 'export_signing_handoff failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ "$WORK_DIR" == /tmp/codexdone-handoff.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

[[ "$OUTPUT_ZIP" == /* && "$OUTPUT_ZIP" == *.zip ]] \
  || fail "output path must be an absolute .zip path"

TOOLS=(
  create_dmg.sh
  generate_dmg_background.swift
  layout_dmg.applescript
  sign_and_notarize_dmg.sh
  verify_release_bundle.sh
)

mkdir -p "$KIT_DIR/script" "$(dirname "$OUTPUT_ZIP")"
README_LINES=(
  "CodexDone signing and notarization handoff"
  ""
  "Requirements:"
  "- Developer ID Application certificate in the signing Mac keychain"
  "- 10-character Apple Developer Team ID"
  "- notarytool keychain profile"
  ""
  "Usage:"
  "  export CODEXDONE_DEVELOPMENT_TEAM=XXXXXXXXXX"
  "  export CODEXDONE_SIGNING_IDENTITY='Developer ID Application: Name (XXXXXXXXXX)'"
  "  export CODEXDONE_NOTARY_PROFILE=profile-name"
  "  ./script/sign_and_notarize_dmg.sh /absolute/path/to/CodexDone.app /absolute/path/to/CodexDone.dmg"
  ""
  "The command signs the embedded HookBridge first, signs the app and DMG, submits the DMG"
  "for notarization, staples the accepted ticket, validates Gatekeeper, and writes a SHA-256 file."
  "Signing certificates, Apple credentials, and notary profiles must remain on the signing Mac."
)
printf '%s\n' "${README_LINES[@]}" > "$KIT_DIR/README.txt"
for tool in "${TOOLS[@]}"; do
  source_path="$ROOT_DIR/script/$tool"
  [[ -f "$source_path" ]] || fail "missing tool: $tool"
  /usr/bin/ditto "$source_path" "$KIT_DIR/script/$tool"
done
/bin/chmod 0755 \
  "$KIT_DIR/script/create_dmg.sh" \
  "$KIT_DIR/script/generate_dmg_background.swift" \
  "$KIT_DIR/script/sign_and_notarize_dmg.sh" \
  "$KIT_DIR/script/verify_release_bundle.sh"

(
  cd "$KIT_DIR"
  /usr/bin/shasum -a 256 README.txt script/* > SHA256SUMS.txt
)

rm -f "$OUTPUT_ZIP"
(
  cd "$WORK_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "$OUTPUT_ZIP" "$(basename "$KIT_DIR")"
)
/usr/bin/unzip -tq "$OUTPUT_ZIP" >/dev/null
printf 'Signing handoff kit: %s\n' "$OUTPUT_ZIP"
