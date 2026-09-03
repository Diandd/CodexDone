#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexDone.xcodeproj"
DERIVED_DATA_PATH="$ROOT_DIR/artifacts/build/DerivedData"
UNIT_RESULT="$ROOT_DIR/artifacts/build/CodexDoneUnitTests.xcresult"
UI_RESULT="$ROOT_DIR/artifacts/build/CodexDoneUITests.xcresult"
UI_LOG="$ROOT_DIR/artifacts/build/CodexDoneUITests.log"
SCREENSHOT_DIR="$ROOT_DIR/artifacts/ui-tests/$(date +%F)"
ATTACHMENT_EXPORT=""

cleanup_ui_artifacts() {
  rm -f -- "$UI_LOG"
  if [[ -n "$ATTACHMENT_EXPORT" \
    && "$ATTACHMENT_EXPORT" == "$ROOT_DIR/artifacts/build/ui-attachments-"* \
    && -d "$ATTACHMENT_EXPORT" ]]
  then
    rm -rf -- "$ATTACHMENT_EXPORT"
  fi
}

trap cleanup_ui_artifacts EXIT

if [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
  selected_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$selected_dir" || ! -x "$selected_dir/usr/bin/xcodebuild" ]]; then
    printf 'CodexDone requires a full Xcode 27 installation.\n' >&2
    exit 1
  fi
  export DEVELOPER_DIR="$selected_dir"
fi

mkdir -p "$DERIVED_DATA_PATH" "$SCREENSHOT_DIR"

remove_result() {
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -rf -- "$path"
  fi
}

stop_ui_test_processes() {
  pkill -x CodexDoneUITests-Runner >/dev/null 2>&1 || true
  pkill -x CodexDone >/dev/null 2>&1 || true
}

fail_ui_export() {
  printf 'UI screenshot verification failed: %s\n' "$1" >&2
  exit 1
}

verify_ui_tests_do_not_synthesize_keyboard_input() {
  local ui_test_source="$ROOT_DIR/CodexDoneUITests"
  local matches

  matches="$(rg -n '\.(typeKey|typeText)\(' "$ui_test_source" || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" >&2
    printf '%s\n' \
      'UI tests must not synthesize keyboard input because XCTest can add a keyboard layout to the user account.' >&2
    printf '%s\n' \
      'Cover keyboard handling with AppKit unit tests and keep UI automation to pointer interactions.' >&2
    exit 1
  fi
}

validate_and_copy_ui_attachments() {
  local manifest="$ATTACHMENT_EXPORT/manifest.json"
  local attachment_records="$ATTACHMENT_EXPORT/validated-attachments.tsv"
  local exported_name
  local suggested_name
  local source_path
  local stable_name
  local mime_type

  [[ -s "$manifest" ]] || fail_ui_export "attachment manifest is missing or empty"

  if ! jq -er '
    def stable_name: sub("_0_[[:alnum:]-]+\\.png$"; ".png");
    [
      .[] as $test
      | $test.attachments[]
      | {
          testIdentifier: $test.testIdentifier,
          exportedFileName: .exportedFileName,
          suggestedHumanReadableName: .suggestedHumanReadableName,
          isAssociatedWithFailure: .isAssociatedWithFailure,
          stableName: (.suggestedHumanReadableName | stable_name)
        }
    ] as $items
    | select(
        (($items | length) == 15)
        and all($items[];
          (.isAssociatedWithFailure == false)
          and (.exportedFileName | type == "string")
          and (.exportedFileName | test("^[[:alnum:]-]+\\.png$"))
          and (.suggestedHumanReadableName | type == "string")
        )
        and (($items | map(.exportedFileName) | unique | length) == 15)
        and (($items | map("\(.testIdentifier)\t\(.stableName)") | sort) == [
          "CodexDoneUITests/testCustomAlertHeadlinesAndOverlayAppearance()\tcompletion-hud-customized.png",
          "CodexDoneUITests/testCustomAlertHeadlinesAndOverlayAppearance()\tcompletion-overlay-customized.png",
          "CodexDoneUITests/testDefaultSoundTestAlert()\tcompletion-alert-settings.png",
          "CodexDoneUITests/testHookEnablementGuideShowsDesktopAndCLIInstructions()\thook-enablement-guide-cli.png",
          "CodexDoneUITests/testHookEnablementGuideShowsDesktopAndCLIInstructions()\thook-enablement-guide.png",
          "CodexDoneUITests/testInitializationGuideOffersHooksAndNotificationSetup()\tinitialization-guide-alert-style.png",
          "CodexDoneUITests/testInitializationGuideOffersHooksAndNotificationSetup()\tinitialization-guide-permissions.png",
          "CodexDoneUITests/testInitializationGuideOffersHooksAndNotificationSetup()\tinitialization-guide-welcome.png",
          "CodexDoneUITests/testMenuBarCompletionList()\tcompletion-menu-popover.png",
          "CodexDoneUITests/testOverlayAndHUDSurfaces()\tcompletion-hud.png",
          "CodexDoneUITests/testOverlayAndHUDSurfaces()\tcompletion-notch-alert.png",
          "CodexDoneUITests/testOverlayAndHUDSurfaces()\tcompletion-overlay.png",
          "CodexDoneUITests/testSettingsWindow()\tcompletion-settings-about.png",
          "CodexDoneUITests/testSettingsWindow()\tcompletion-settings-diagnostics.png",
          "CodexDoneUITests/testSettingsWindow()\tcompletion-settings.png"
        ])
      )
    | $items[]
    | [.exportedFileName, .suggestedHumanReadableName]
    | @tsv
  ' "$manifest" > "$attachment_records"
  then
    fail_ui_export "manifest must contain exactly the fifteen required, successful scenario screenshots"
  fi

  while IFS=$'\t' read -r exported_name suggested_name; do
    source_path="$ATTACHMENT_EXPORT/$exported_name"
    [[ -f "$source_path" && ! -L "$source_path" && -s "$source_path" ]] \
      || fail_ui_export "an exported screenshot is missing, unsafe, or empty"
    mime_type="$(/usr/bin/file -b --mime-type "$source_path" 2>/dev/null || true)"
    [[ "$mime_type" == "image/png" ]] \
      || fail_ui_export "an exported screenshot is not a PNG image"
  done < "$attachment_records"

  while IFS=$'\t' read -r exported_name suggested_name; do
    stable_name="$(printf '%s' "$suggested_name" | sed -E 's/_0_[[:alnum:]-]+\.png$/.png/')"
    cp "$ATTACHMENT_EXPORT/$exported_name" "$SCREENSHOT_DIR/$stable_name"
  done < "$attachment_records"
}

run_ui_tests() {
  xcodebuild -quiet \
    -project "$PROJECT_PATH" \
    -scheme CodexDone \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$UI_RESULT" \
    -parallel-testing-enabled NO \
    -only-testing:CodexDoneUITests \
    test 2>&1 | tee "$UI_LOG"
}

remove_result "$UNIT_RESULT"
remove_result "$UI_RESULT"
verify_ui_tests_do_not_synthesize_keyboard_input

xcodebuild -quiet \
  -project "$PROJECT_PATH" \
  -scheme CodexDone \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$UNIT_RESULT" \
  -parallel-testing-enabled NO \
  -only-testing:CodexDoneTests \
  test

APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/CodexDone.app"
"$ROOT_DIR/script/verify_hook_bridge.sh" "$APP_BUNDLE"

stop_ui_test_processes
set +e
run_ui_tests
ui_test_status=$?
set -e
stop_ui_test_processes
if [[ "$ui_test_status" -ne 0 ]] \
  && grep -Eq 'failed to initialize for UI testing|Timed out while enabling automation mode' "$UI_LOG"
then
  printf 'UI automation service initialization timed out; retrying once.\n' >&2
  remove_result "$UI_RESULT"
  stop_ui_test_processes
  set +e
  run_ui_tests
  ui_test_status=$?
  set -e
  stop_ui_test_processes
fi
if [[ "$ui_test_status" -ne 0 ]]; then
  remove_result "$UI_RESULT"
  exit "$ui_test_status"
fi

ATTACHMENT_EXPORT="$ROOT_DIR/artifacts/build/ui-attachments-$(date +%Y%m%d-%H%M%S)-$$"
xcrun xcresulttool export attachments \
  --path "$UI_RESULT" \
  --output-path "$ATTACHMENT_EXPORT" \
  --filter "*.png"

validate_and_copy_ui_attachments

xcodebuild -quiet \
  -project "$PROJECT_PATH" \
  -scheme CodexDone \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

printf 'Unit tests, Hook Bridge smoke, UI tests, screenshots, and Release build passed.\n'
