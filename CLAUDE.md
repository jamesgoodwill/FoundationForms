# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Greenfield SwiftUI iOS app, scaffolded from Xcode's default App template (Xcode 26.2). At the time of writing, `FoundationForms/` contains only the `@main` `FoundationFormsApp` and a placeholder `ContentView`. The project is **not** under git.

The intended direction is implied by `basic_information.json` at the repo root, not by code: a JSON-driven form renderer. The schema groups `fields` into `rows`, with field `type`s including `text`, `date`, `textarea`, `singleSelect`, and `address` (a composite type with nested `subFields`). Fields carry validation/presentation metadata (`isRequired`, `maxCharacters`, `style`), `role` hints (e.g. `state`, `zip`) for keyboard/formatter selection, and `key` references to external value lists (e.g. `us_state_codes`). Treat this file as the canonical example of the input format the app should consume.

## Build & run

Single target/scheme, both named `FoundationForms`:

```bash
# Build for the simulator (iOS 26.2 deployment target — pick any installed iOS 26.x simulator)
xcodebuild -project FoundationForms.xcodeproj -scheme FoundationForms \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run on a booted simulator
xcrun simctl install booted /path/to/FoundationForms.app
xcrun simctl launch booted com.emergent.FoundationForms
```

There is no test target yet. If you add one, prefer `xcodebuild test -scheme FoundationForms -destination ...` and a Swift Testing (`import Testing`) target over XCTest unless the user specifies otherwise — the project already opts into modern Swift defaults (see below).

## Architecture: MVVM

New and updated features must follow MVVM. Keep the layers separated:

- **Model** — plain Swift types for form schema + state (e.g. decoded `basic_information.json` structures, field values, validation results). No SwiftUI imports.
- **ViewModel** — an `@Observable` (or `ObservableObject`) class that owns presentation state, exposes intent methods (`load()`, `submit()`, `update(fieldID:value:)`), and performs decoding/validation/persistence by delegating to services. ViewModels are the only place views talk to for data; views never reach into models or services directly.
- **View** — SwiftUI views are thin: bind to a ViewModel, render state, forward user actions back to the ViewModel. No business logic, no I/O, no `JSONDecoder` calls inline. Previews construct a ViewModel with stub data.

Practical rules:
- One ViewModel per screen/feature; share via dependency injection (init parameter or `@Environment`), not singletons.
- Respect the project's `MainActor` default — keep ViewModels MainActor-isolated and push decoding/network work to `nonisolated` async methods or actors.
- Field-rendering subviews (per `type`: `text`, `date`, `address`, `singleSelect`, `textarea`) should each take a binding/value + a callback into the parent ViewModel — don't give every field its own ViewModel unless it owns nontrivial state.

## Project structure conventions

- **Filesystem-synchronized group** (`PBXFileSystemSynchronizedRootGroup`): the `FoundationForms/` folder is auto-synced into the Xcode target. **Do not edit `project.pbxproj` to add new Swift sources** — just create the file under `FoundationForms/` and Xcode picks it up. This is a meaningful difference from older Xcode projects.
- `basic_information.json` lives at the repo root, outside the app bundle. If form definitions need to ship with the app, they have to be added to `FoundationForms/` (or a subfolder) so the synchronized group includes them, and then loaded from `Bundle.main`.
- Universal app (iPhone + iPad), portrait + landscape on both. Keep layouts size-class-aware.

## Swift language settings to respect

The target is configured with:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — top-level types are MainActor-isolated by default. Be explicit with `nonisolated` / `actor` when work should run off the main actor (e.g., JSON decoding of large form schemas, network I/O).
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — write code that compiles cleanly under the stricter upcoming-feature checks; don't suppress warnings to paper over isolation issues.
- `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` and `SWIFT_EMIT_LOC_STRINGS = YES` — user-facing strings should go through `String(localized:)` / `LocalizedStringKey` so they get extracted into the String Catalog, not raw `String` literals.
