# AGENTS.md

Palette Studio (formerly **Palette 3D**): a multiplatform SwiftUI app (iOS, macOS, visionOS 26) that generates color palettes and plots them in a 3D sphere (lightness × chroma × hue), with a SwiftData library and import/export (.gpl, .clr, palette images, lospec).

**Never rename `palette3d` identifiers** — bundle id, CloudKit container, exported UTTypes in `Palette-Studio-Info.plist`. Changing them orphans user data. `onOpenURL` matches both `/palettestudio/` and the legacy `/palette3d/` path.

## Build & test

```sh
xcodebuild -scheme "Palette Studio" test   # Swift Testing, unit-only
xcodebuild -scheme "Palette Studio" test -only-testing:"Palette StudioTests/PaletteTests/palettePersistsThroughSwiftData"
```

Don't pin destinations. Tests here cover only the app layer (SwiftData, `@Model` bridge, undo, editing rules); color math is tested in PaletteKit. Newer-than-26 APIs are `#available`-gated (`PaletteGridView`, `PaletteListView`, `PaletteEditorView`).

## PaletteKit

Remote package (`256Arts/PaletteKit`, shared with Sprite Pencil / Sprite Catalog) owning the color model, generator, metrics, every file format, and premade palettes. **A color type that looks undefined here is PaletteKit's.** ChromaKit comes transitively; app code never imports it.

## Key rules

- **`Palette`** in app code is the SwiftData `@Model`; the value type is `PaletteKit.Palette`. Convert with `Palette.init(_:)` / `snapshot()` (use the snapshot for export/drag off the main actor).
- **Perfect vs plain:** a perfect palette stores generator `parameters` (generation is deterministic); plain has `parameters == nil`. Any manual color edit must call `onManualEdit` → `markCustomized()`, which locks parameters. "Discard Manual Edits" regenerates and unlocks.
- **CloudKit:** every `Palette` property optional/defaulted, no `@Attribute(.unique)` (`schemaIsCloudKitCompatible` guards). New fields need a Production schema deploy. Entitlements carry both iOS and macOS `aps-environment` keys on purpose.
- **Undo** is observed, not wrapped: the editor watches `palette.editState` and registers via `Palette.registerUndo(from:with:)`. Don't switch to SwiftData's undo — it desyncs the transient generator and splits typing per keystroke.
- **Sphere view:** keep `UnlitMaterial` (lit shading falsifies colors). Plot positions as-is — the sphere surface *is* Display P3 (`chromaScale`); don't normalize away the chroma parameter.
- **Tabs:** `MainView` stays a plain tab bar (not `.sidebarAdaptable`); the editor hides it via `hidingTabBar()`.
- **Menu commands** (`PaletteCommands`) act through focused scene values, so the editor owns `displayMode` / `showingAddColor`. `PaletteExportMenu` is the single export list.
- **Imports** go through `PaletteKit.Palette(file:colorSpace:)` — never switch on file extension. All creation paths funnel through `PaletteListView.create(_:)` (also drives `ReviewPrompt`).
- `handpickedPalettes` mints fresh ids per call — resolve once into `@State`, never from `body`.
- **Text mode** parses only `lch()`/`oklch()` as input; other notations are output-only.
- **`WebColorRenderer`** (offscreen `WKWebView` for CSS color math) must rebuild its page when WebKit kills the content process and retry once. Single-color `resolve(_:)` validates with `CSS.supports`; the batch call reports bad input as black.
- **Hue rotation** in `ComplementsView` stays an exact CSS `calc()` expression (no formatted decimals — locale commas break CSS).
- **ColorDetailsView `Provenance`** (`.palette` / `.derived` / `.scratch`) is explicit, not inferred from closures. `InspectedColor` carries its own `UUID` because `PaletteColor.id` is its value.
- **`ColorImport`:** the menu only chooses; `importingColor(_:perform:)` on the *content* owns presentation (toolbar-attached presentations are unreliable).
- **Analysis** converts each color to a `ColorMetrics.Sample` once (pairwise loop is O(n²)) and runs in `.task(id:)`, not `body`. `ColorMetrics.wcagGrade(_:)` is shared with Pairs.
- **visionOS:** inspector sits beside the display; "Open in Volume" opens a `.volumetric` sphere (`VolumetricDisplayView`, looked up by `PersistentIdentifier`).

## Screenshots

`Scripts/screenshots.sh [iphone duo ipad mac vision]` forwards to the shared runner in iCloud `Repos/Scripts/screenshots` — don't reimplement its simulator/capture/compositing logic here. This repo owns `.screenshots.conf`, `ScreenshotMode` (in-memory seeded store with a pinned date, via `-screenshotMode`), and `PaletteUITests/ScreenshotTests.swift` (run under the **Screenshots** scheme). The UI test runner's sandbox is off so it can hand Mac capture requests to the script via `/tmp`. Wrong-sized Mac shot → change `defaultSize` in `PaletteStudioApp`, not the script.
