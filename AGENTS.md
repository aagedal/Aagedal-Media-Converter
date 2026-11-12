# Repository Guidelines

## Project Structure & Module Organization
The macOS app source lives in `Aagedal Media Converter/`. Core services and conversion logic are in `Aagedal Media Converter/Logic/`, UI in `Aagedal Media Converter/UI/`, shared helpers in `Aagedal Media Converter/Utils/`, Shortcuts intents in `Aagedal Media Converter/AppIntents/`, and assets in `Aagedal Media Converter/Resources/`. Bundled binaries (ffmpeg/ffprobe and helpers) are in `Aagedal Media Converter/Binaries/`. Tests live in `Aagedal Media ConverterTests/` and `Aagedal Media ConverterUITests/`. The Xcode project is `Aagedal Media Converter.xcodeproj`.

## Build, Test, and Development Commands
```bash
open "Aagedal Media Converter.xcodeproj"
xcodebuild -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter" \
  -configuration Debug build
xcodebuild test -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter"
xcodebuild test -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter" \
  -only-testing:"Aagedal Media ConverterUITests"
```
Use Release builds when validating packaging or distribution.

Before pushing or opening a pull request, run `scripts/ci-local.sh` (add `--release` for packaging changes). It runs the checks from `.github/workflows/validate.yml`, which no longer runs on pull requests.

## Coding Style & Naming Conventions
Use 4-space indentation and standard Swift/SwiftUI conventions. Types use `UpperCamelCase`, functions/vars use `lowerCamelCase`, and file names generally mirror the main type (e.g., `ConversionManager.swift`). Common suffixes include `*View`, `*Manager`, `*Service`, and `*SettingsView`. Prefer Swift concurrency (`async`/`await`, actors) where it already exists.

## Testing Guidelines
Tests use XCTest. Keep new unit tests in `Aagedal Media ConverterTests/` with `test*` method names, and add UI coverage in `Aagedal Media ConverterUITests/` for user flows. Many tests generate small media fixtures with the bundled ffmpeg. Also check preview playback (AVPlayer and MPV), conversion, and folder bookmark persistence in the app after changes.

## Commit & Pull Request Guidelines
Recent commits are short, sentence-style descriptions, often past tense and sometimes ending with a period. Follow that style (e.g., "Fix metadata probe failure."). PRs should include a clear summary, the tests run (including the `scripts/ci-local.sh` result), and screenshots for UI changes. Call out any updates to bundled binaries or licenses.

## Security & Configuration Tips
The app is not sandboxed (`ENABLE_APP_SANDBOX = NO`). Security-scoped bookmarks still persist user-chosen folders and files across launches, so keep the existing bookmark plumbing. When touching ffmpeg/ffprobe or other tools, keep references bundle-based rather than hardcoded paths.
