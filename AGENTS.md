# Repository Guidelines

CodexDone is a native macOS menu-bar app that alerts users when a Codex Desktop or CLI turn stops.

## Project Structure

- `CodexDone/App/` starts the app. `Views/` contains menu-bar, settings, and alert interfaces. `Stores/DesktopCompletion/` handles session state and persistence, while `Services/` handles hooks, notifications, and audio.
- `CodexDoneHookBridge/` contains the helper that receives hook events. Put event formats and parsing used by both targets in `CodexDone/Shared/`. When adding a Swift file, include it in the appropriate Xcode targets.
- `CodexDone/Resources/` holds icons and translations. Keep English and Simplified Chinese keys in sync in `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.

## Build, Run, and Test

Use macOS 27 and a full Xcode 27 installation. Run these commands from the repository root.

- `./script/build_and_run.sh --build-only` builds the Debug app and checks for the bundled helper.
- `./script/build_and_run.sh --verify` builds and launches the app, then checks that its process stays up. To try real events, install hooks in Settings → General, then trust and enable `UserPromptSubmit` and `Stop` in Codex.
- `./script/test.sh` runs unit tests, smoke-tests the helper, runs UI tests, validates screenshots, and builds Release.

## Swift Style

Use two-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for methods and properties. Match the surrounding Swift formatting. The project uses Swift 6 with strict concurrency checking.

## Testing Guidelines

Place unit tests in `CodexDoneTests/<Component>Tests.swift`. Most suites use Swift Testing with behavior-named methods such as `promptStartsRunning()` and `#expect` assertions. UI tests in `CodexDoneUITests/` use XCTest and `test…` methods. Use pointer interactions in UI tests and cover keyboard handling with AppKit unit tests. When renaming a screenshot attachment, update the expected name in `script/test.sh`.

## Commits and Pull Requests

Follow the history’s `feat:` and `fix:` prefixes with a short imperative summary, such as `fix: avoid pre-notarization Gatekeeper launch`. In a pull request, describe the behavior change, link any related issue, and list the checks you ran. For visible changes, include the relevant screenshot from `artifacts/ui-tests/YYYY-MM-DD/`.
