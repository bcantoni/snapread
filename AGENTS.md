# SnapRead — Agent Notes

SnapRead is a native macOS (SwiftUI) app that triages recent iPhone screenshots: it OCRs each one, interprets it with the on-device Apple Intelligence LLM, extracts links, and lets the user open/copy links, archive, or batch-delete screenshots from Photos.

The app lives in `SnapRead/`. The `snapread.py` CLI at the repo root is a legacy Python proof of concept — leave it alone unless explicitly asked.

## Building

The `.xcodeproj` is generated from `SnapRead/project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked in. Never edit `project.pbxproj` directly — change `project.yml` and regenerate.

```bash
cd SnapRead
xcodegen generate
xcodebuild -project SnapRead.xcodeproj -scheme SnapRead -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/SnapRead.app
```

Requires macOS 26 (Tahoe) and Xcode 26 — the app uses the FoundationModels framework. Builds are ad-hoc signed (no Developer ID), so macOS may re-prompt for Photos permission after a rebuild.

## Code layout (`SnapRead/SnapRead/`)

- `SnapReadApp.swift` — app entry point
- `Models/ScreenshotItem.swift` — a screenshot plus its OCR/interpretation state
- `Models/TriageStore.swift` — triage decisions (archive/delete/skip), persisted to `triage.json` in the app container
- `Views/` — `TriageView` (main one-at-a-time flow, keyboard-first), `InterpretationPanel`, `FinishedView` (end-of-queue, applies batched deletes), `SettingsView` (lookback window)
- `Services/PhotoLibraryService.swift` — PhotoKit fetch of screenshot assets, iCloud downloads, batch deletion
- `Services/OCRService.swift` — Vision OCR plus NSDataDetector link extraction (upgrades scheme-less URLs to `https`)
- `Services/InterpretationService.swift` — FoundationModels interpretation (category/title/summary), with a regex-heuristic fallback when Apple Intelligence is unavailable

## Conventions and constraints

- Everything runs on-device; don't add network calls or send user data anywhere.
- The app is sandboxed with the Photos entitlement only — new entitlements go in `project.yml`.
- Deletes are never applied one-by-one: they're collected during triage and applied as a single batch (one system confirmation) from the finished screen. Keep it that way.
- Keyboard-first UI: new actions should get a shortcut and appear in the triage view's key handling (see the table in `README.md`).
- If Apple Intelligence is unavailable, interpretation must degrade gracefully to the heuristic path labeled "Basic analysis" — don't make FoundationModels a hard requirement at runtime.
