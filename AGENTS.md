# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The app was once **Palette 3D**. Identifiers that outlive a rename keep that spelling on purpose —
the bundle id and CloudKit container (`palette3d`) and the exported UTTypes in `Palette-Studio-Info.plist`;
changing them orphans users' data and drags. The site moved to `/palettestudio/`, but `/palette3d/`
still redirects and still routes App Store event links, so `onOpenURL` matches either.

Palette Studio is a multiplatform SwiftUI app (iOS, macOS, visionOS) that procedurally generates color palettes and visualizes them in 3D. Colors are positioned inside a sphere whose axes are perceptual color dimensions (lightness, chroma, hue). Palettes are saved to a SwiftData library, and can also be imported from and exported to standard formats (.gpl, .clr, palette images, lospec.com).

## Build & Test

The project is an Xcode project (`Palette Studio.xcodeproj`) with one app target (`Palette Studio`) and one test target (`Palette StudioTests`). Tests use Swift Testing (`import Testing` / `@Test`), not XCTest. The scheme's test action covers `Palette StudioTests`. The color model, generator, and file formats are tested in **PaletteKit** (`swift test` in its own repo); the tests here cover only this app's layer — SwiftData persistence, the `@Model` ↔ `PaletteKit.Palette` bridge, undo, and the editing rules (`EditingTests`: the customization lock, reordering, format pins, WCAG grades).

```sh
# Build (let xcodebuild pick a destination, or use Xcode directly)
xcodebuild -scheme "Palette Studio" build

# Run all tests
xcodebuild -scheme "Palette Studio" test

# Run a single test
xcodebuild -scheme "Palette Studio" test -only-testing:"Palette StudioTests/PaletteTests/palettePersistsThroughSwiftData"
```

Note: the app targets **OS 26** (iOS/macOS/visionOS 26.0). Newer APIs are used where they earn their place, gated with `#available` — see `PaletteGridView` (reorder containers), `PaletteListView` (`ToolbarOverflowMenu`), and `PaletteEditorView` (`visibilityPriority`, which is macOS 26.1 but iOS 27).

Note: destinations/platforms are intentionally not pinned here — choose a current simulator or device at build time, as available SDKs change with Xcode updates.

## App Store screenshots

`Scripts/screenshots.sh [iphone ipad mac vision]` (no arguments runs all four) drives the app through
its screens and writes PNGs to `Raw Assets/Screenshots/` as `Phone 6.9 1.png`, `Pad 13 1.png`,
`Mac 1.png`, `Vision 1.png`. That folder is a symlink out to iCloud, so nothing lands in the repo;
the hand-made shots it replaced are archived beside them in `Old (Manual)/`.

The runner itself is **shared across every app**, in iCloud at `Repos/Scripts/screenshots` (override the
location with `APP_SCRIPTS_DIR`); `Scripts/screenshots.sh` only forwards to it. This repo owns three
things: `.screenshots.conf` (project, scheme, bundle id, Mac process name), the seeding in
`ScreenshotMode`, and the walk in `PaletteUITests/ScreenshotTests.swift`. Booting simulators, freezing
the status bar, unpacking attachments, the Mac capture handshake, and compositing all live in the
shared script and its `screenshot-support/` helpers — don't reimplement them here.

- The app is launched with `-screenshotMode`. `ScreenshotMode` (`Shared/Utilities/`) then swaps the
  SwiftData store for an in-memory one seeded with a generated palette plus premades, so a run neither
  shows nor touches the real library, and pins the seed's date — `handpickedPalettes(on:)` promotes a
  seasonal palette, so an unpinned run would differ by month.
- `PaletteUITests/ScreenshotTests.swift` is the driver: one XCUITest walking one launch, attaching each
  shot with `.keepAlways` (attachments on a passing test are discarded otherwise). It runs under the
  **Screenshots** scheme, kept separate so `xcodebuild test` on the `Palette Studio` scheme stays unit-only.
- Simulator shots come from `XCUIScreen.main.screenshot()`, already the exact pixel size the store
  wants. The script freezes the status bar to 9:41 first.
- Mac shots are taken by the *script*, not the test. `screencapture -l <windowID>` reads the window's
  own buffer, so it arrives correctly masked to the rounded corners with real alpha and the system's
  own shadow — where `XCUIElement.screenshot()` crops the screen to the window's frame and so loses
  the shadow and leaves desktop in the corners. But `screencapture` needs Screen Recording, which the
  test runner has no grant for and the shell does, so the test writes a `request-<name>` file into
  `/tmp/app-store-screenshots` and blocks until the script's watcher answers with `done-<name>`.
  `screenshot-support/WindowID.swift` does the window lookup (listing windows needs no grant; capturing does).
  This is also why `PaletteUITests.entitlements` turns the runner's sandbox **off**: a sandboxed
  runner cannot write `/tmp`, and its own container is unreadable to the script, so they would have
  nowhere to meet.
- `screenshot-support/ComposeMacScreenshot.swift` then only scales and centres that capture on a 2560x1600 canvas
  (an accepted App Store size) over a wallpaper from iCloud — no mask to rebuild, no shadow to fake.
  Override the backdrop with `SCREENSHOT_MAC_BACKGROUND`; if it is unreachable the compositor falls
  back to a flat colour rather than failing the run.
- The Mac shots photograph the app's own `defaultSize` — 880x560 (visionOS keeps 1024x640), set in `PaletteStudioApp` — rather than
  a size invented for screenshots. macOS restores a saved window frame ahead of `defaultSize`, so the
  script clears the app's `NSWindow Frame` defaults first; that is the one piece of local state a run
  touches. If a screenshot looks wrong-sized, change `defaultSize`, not the script.
- Two hooks exist purely so the test can steer: `PaletteRow.<name>` accessibility identifiers in
  `PaletteListView`, and accessibility labels on `DisplayView`'s display-mode picker (which was three
  unlabelled SF Symbols).

## Dependencies

- **PaletteKit** (`https://github.com/256Arts/PaletteKit`, a remote Swift package) — the shared color engine: `PaletteColor`, `ColorSpace`, `ColorRepresentation`, `Gamut`, `SRGB8`, `PaletteGenerator`, `ColorMetrics`, every file format, the premade palettes, and reusable palette SwiftUI. Shared with Sprite Pencil and Sprite Catalog. **The color model and its math are not in this repo** — when a color type looks undefined here, it's PaletteKit's.
- ChromaKit arrives *transitively*, via PaletteKit. The app no longer imports it: everything it needs (perceptual metrics, P3 conversion) is exposed by PaletteKit, so `Lab`/`P3` never appear in app code.

## Architecture

The app has two layers: an abstract palette model (resolution-independent fractions) and per-color-space realization (actual displayable/CSS colors). Keeping these separate is the core design idea — and it now lives in **PaletteKit**, not here. On top sits this app's SwiftData palette library, its editor, and the 3D display.

**`Palette` is ambiguous by design.** In app code `Palette` always means the SwiftData `@Model`; PaletteKit's storage-agnostic value type is spelled `PaletteKit.Palette`. They convert via `Palette.init(_:)` (an import lands as a plain palette) and `Palette.snapshot()` (a value copy for export/drag, so no `@Model` is touched off the main actor).

**Palette library** (`Shared/Model/Palette.swift`):
- `Palette` is a SwiftData `@Model`: `name`, optional `parameters` (a `PaletteGenerator.Parameters`), `colors`, `isCustomized`, `dateModified`. A **perfect palette** keeps its generator parameters (created via `Palette.perfect(...)`); a **plain palette** is just a color list with `parameters == nil` (created via `Palette.plain(...)`, e.g. imports).
- Once the user manually edits a color, `isCustomized` locks generation (`canEditParameters` becomes false) so parameter changes can't overwrite their work. Generation is deterministic, so "Discard Manual Edits" exactly reproduces the perfect palette and unlocks the parameters again.
- `PaletteStudioApp` creates one shared `ModelContainer` used by every window (including the visionOS volume), synced through CloudKit (`iCloud.com.jaydenirwin.palette3d`). CloudKit requires every `Palette` property to be optional or defaulted and forbids `@Attribute(.unique)`; `schemaIsCloudKitCompatible` guards this. The entitlements file is shared by every platform, so it carries both `aps-environment` (iOS/visionOS) and `com.apple.developer.aps-environment` (macOS) — signing keeps whichever applies. New model fields need a schema deploy to Production in the CloudKit Console before release.

**Generation pipeline** (`PaletteGenerator` → `[PaletteColor]`) — **all of it lives in PaletteKit**; the app only drives it and persists the `Parameters`:
- `PaletteGenerator` (`@Observable`) wraps a `Parameters` struct (Codable/Equatable — this is what `Palette` persists) and `generate()` produces the colors. Generation is deterministic, which is what lets the app store the recipe instead of the colors. It works purely in **normalized fractions** (lightness, chroma, hue) and is unaware of any concrete color space. It models the palette as a sphere: lightness is the vertical axis, and each lightness layer is a disc whose radius (`sqrt(1 - (lightness*2-1)^2)`) shrinks toward the poles; chroma is radial distance, hue is the angle around the disc.
- `PaletteColor` is one color as `lightnessFraction` / `chromaFraction` / `hueAngle` plus an optional user-facing `name`. It is **color-space agnostic** until realized — `color(colorSpace:)`, `cssString(...)`, `hexString(...)`, etc. map fractions to absolute values (`chromaFraction * ColorSpace.chromaScale`) and convert via ChromaKit. It also parses inbound colors (`init(css:)`, `init(hex:colorSpace:)`, `init(sRGB8BitRed:...)`, `init(_ p3:colorSpace:)`). The `visualizedX/Y/Z` properties map a color to 3D sphere coordinates for the RealityKit view. `chromaScale` is *the* diameter knob: it's how far Display P3 reaches once each lightness layer is shrunk onto the sphere, so `chromaFraction == 1` lands on the sphere's surface, P3 fills the diameter, and wide-gamut colors plot outside it — hence the generator's chroma parameter reading "% of P3".
- `ColorRepresentation` + `Gamut` (PaletteKit) enumerate the text formats a color can be expressed in (CSS notations, RGB/Hex/HSL/HSB/HWB, SwiftUI/UIKit/AppKit/Java/Android snippets), grouped by gamut with clamping detection — used by the color detail rows and the export menu.
- `ColorFormat` (`Shared/Model/ColorFormat.swift`) pairs a representation with a gamut, because the framework snippets exist in both P3 and sRGB — that pair is what a user pins ("SwiftUI P3"). `PinnedColorFormats` persists the pins in `@AppStorage`, read by both `ColorDetailsView` (which does the pinning, and collapses the rest behind "All Formats") and the editor's export menu. `FormatLabel` (`Shared/Views/`) flags any format whose gamut clamps the color(s) — the warning takes the label's *icon* slot, since a `Menu` keeps only a label's title and image.

**Navigation & state flow:** the root view is `MainView` (`Shared/Views/`), a `TabView` over three tabs — Palettes (`PaletteListView`), Pairs (`PairsView`), and Color (a `ColorDetailsView` over one scratch color that `MainView` holds, so it survives tab switches). Each tab owns its own `NavigationStack`. It stays a *tab bar* at every size — deliberately not `.sidebarAdaptable`, since three peer destinations aren't a hierarchy and the editor has no use for a second column — and the pushed editor hides it via `hidingTabBar()` (`MainView.swift`), which is a no-op on macOS where `.tabBar` doesn't exist. An import arriving by URL can land behind an unselected tab, so `PaletteListView.onExternalImport` lets it ask `MainView` to bring the Palettes tab forward — the lospec path pushes an editor, which would otherwise happen out of sight.

Inside that first tab, `PaletteListView` (`Shared/Views/Library/`) is a `NavigationStack` over a `@Query` of saved palettes, sorted by `dateModified`. Below them, `PremadePaletteGallery` scrolls PaletteKit's `handpickedPalettes` (date-aware: the seasonal palette for today is promoted to the top), and tapping one lands a copy through the same path as an import. Unlike `premadePalettes`, that call isn't memoized and mints fresh palette ids each time, so the gallery resolves it once into `@State` rather than reading it from `body`. The empty state is a list row rather than an overlay, so it can't blanket that gallery. Every creation path funnels through `create(_:)`, which also counts toward `ReviewPrompt` (`Shared/Utilities/`): the rating ask comes on returning to the list after the 3rd palette, once per version, never in screenshot mode — `ShareLink` exports report no completion, so they can't be the trigger. Selecting a palette pushes `PaletteEditorView`, which owns a transient `PaletteGenerator` + `paletteText` (seeded from the palette in `load()`). `PaletteInspectorView` is the trailing panel (an `.inspector`, or side-by-side on visionOS) and is always present: it switches between `ParametersView` and `PaletteAnalysisView` while `canEditParameters`, and drops to the analysis alone otherwise — which is why neither the panel nor the button that reopens it is gated on the parameters, and why a palette without them opens the drawer at its smallest detent. Each parameter change triggers `regenerate(...)`, which writes `parameters`/`colors` back to the model. Any manual color edit flows through `onManualEdit` → `markCustomized()`. **Undo** is observed, not wrapped: the editor watches `palette.editState` (colors, parameters, `isCustomized`) and registers each change on the window's `UndoManager` via `Palette.registerUndo(from:with:)` (`Palette+Undo.swift`), so every `DisplayView` edit path is covered and undoing a first edit unlocks the parameters. A text-editor session is held until focus leaves and lands as one step; an undo that restores parameters pushes them back into the generator. Steps are dropped when the editor disappears. Not SwiftData's own undo — it would desync the transient generator and split typing per keystroke.

**Menu bar commands** (`Shared/Views/PaletteCommands.swift`, applied on every platform so iPad's menu gets them too): File ▸ New Perfect Palette (⌘N; New Window moves to ⌥⌘N) / Import, View ▸ Sphere/Grid/Text (⌘1–3) plus the system `InspectorCommands` (⌃⌘I), and Palette ▸ Add Color (⇧⌘N) / Export. They act through focused scene values — `PaletteListView` publishes `PaletteLibraryFocus`, `PaletteEditorView` publishes `PaletteEditorFocus` — which is why the editor, not `DisplayView`, owns `displayMode` and `showingAddColor`. `PaletteExportMenu` is the one export list, shared by the toolbar and the menu bar.

**Import/Export** — the parsers and `Transferable`s (GIMP `.gpl`, `NSColorList` `.clr`, 1px palette images, lospec.com's `lospec-palette://` scheme registered in `Palette-Studio-Info.plist`) all live in **PaletteKit**. The app only funnels: `PaletteListView.importFiles(_:)` hands any URL to `PaletteKit.Palette(file:colorSpace:)` — which picks the parser itself, so the app never switches on the file extension — and lands the result as a plain palette. Exports pass `palette.snapshot()` to PaletteKit's `GIMPPaletteExport` / `PaletteImageExport` / `PaletteColorListExport`.

**Analysis** (`Shared/Views/Analysis/`): `PaletteAnalysisView` is a read-only panel (in the editor's inspector) with pairwise ΔE₀₀ / WCAG contrast statistics and coverage, computed from PaletteKit's `ColorMetrics`. Its Color Vision section reruns the pairwise ΔE through `ColorVision` (`Shared/Model/`, Machado 2009 in linear sRGB) per deficiency; the grid's filter menu previews the same simulation. `ColorVision` returns a `PaletteColor`, so drawing and metrics need no second path. It converts each color to a `ColorMetrics.Sample` once and compares samples — the pairwise loop is O(n²) and must not re-convert. It also lives beside the controls that edit the palette, so the analysis is held in `@State` behind a `.task(id:)` rather than computed from `body`. `PairsView` — the Pairs tab, and a root rather than a sheet, so it carries no Close button — compares two colors via CSS `color-mix()`/gradients in multiple interpolation spaces, resolved by `WebColorRenderer` (an offscreen `WKWebView` that does only the color math; results are drawn natively). WebKit reclaims a backgrounded app's content process, which leaves the web view alive but takes `window.resolveColors` with it — so the renderer implements the failure delegates, rebuilds the page when it's lost, and retries an evaluation once, since the call that discovers a dead page is also the one that triggers the reload. Without that, every ramp, wheel, and bar comes back empty until the app is relaunched. Its two colors are picked through `ColorPairBar` rather than `ColorPicker`s: one capsule split between them, each half a `ColorDetailsButton` into that color's details — the sheet holds a picker of its own plus the formats, contrast, ramps, and imports, so the swap only adds. At a regular width the page shows everything at once — each interpolation space's mix swatch beside its gradient on one row, with the statistics as their own always-visible sections — so the Mix/Gradient/Stats picker exists only in compact width, where the three have to take turns. macOS has no `horizontalSizeClass`, so it reads as regular unconditionally. Every mode shows that same capsule; a `mix` binding is what makes the split movable, and `nil` fixes it at half wherever no mix is on screen, so changing mode doesn't rearrange the page. The drag lives on an invisible 44pt `grabber` strip over the divider, not on the track: the halves are buttons now, and a track-wide drag would land on them as taps. That strip is also where the `Slider` accessibility representation sits, leaving the halves as plain buttons. A Mix swatch taps into its details; a Gradient row gets a copy button instead, since a gradient is the one thing here that isn't a color — it copies `linear-gradient(in <space>, …)`, which reproduces the bar's colors exactly because the sampled stops take CSS's same default `shorter hue` path. No direction is emitted — where the gradient points is the caller's decision, not the bar's.

## DisplayView

`DisplayView` (`Shared/Views/Display/`) renders and edits one palette's colors. It takes the generator, a `Binding` to the palette's colors, the CSS text binding, and an `onManualEdit` callback. It owns the toolbar's Add Color button, which belongs to the palette rather than to any one mode. Three display modes:
- `sphere` — `PaletteSphereView`, a RealityKit `RealityView` placing a sphere entity per color at its visualized 3D position (`.orbit` camera controls except on visionOS). Swatches use `UnlitMaterial` — a lit material shades each sphere by where the scene's light sits, which both falsifies the color being judged and gives the graph a dark back side to orbit into; don't "improve" it back to `SimpleMaterial`. Positions are plotted as-is — the model sphere's surface *is* Display P3, so a palette below 100% chroma reads as a smaller sphere and one above it breaks out; don't reintroduce a normalization that cancels the chroma parameter. Tapping a sphere opens that color's details. The same view backs the visionOS `.volumetric` window (`VolumetricDisplayView`, which looks the palette up live from SwiftData by `PersistentIdentifier`).
- `grid` — `PaletteGridView`, a `LazyVGrid` of swatches sized to fit the whole palette on screen (`fittedSize`, floored at 44pt); pinching zooms relative to that fit, and larger sizes reveal name, then hex. Supports drag-to-reorder (OS 27 `reorderable()`; applied via `ReorderDifference.apply(to:)` in `Shared/Utilities/`), dragging swatches out as colors (`DraggableColor`), dropping colors in, context-menu delete, and a gamut filter that flags colors clamped on the current display. The reorder and drag containers are OS 27-only, so on OS 26 each swatch carries its own `draggable` and the context menu gains Move Left / Move Right — the grid reports reorders as the new `[PaletteColor]` order rather than a `ReorderDifference`, so its API stays version-agnostic.
- `text` — a `TextEditor` of CSS color strings. This mode is **bidirectional**: editing text re-parses colors via `PaletteColor(css:)`. Only `lch()` and `oklch()` are parseable as input; `lab`, `oklab`, and P3 are output-only (an alert warns the user). Grid/sphere edits sync back into the text unless it's focused.

Tapping a color opens `ColorDetailsView` (`Shared/Views/ColorDetail/`) — preview, color picker, and the color's value in every `ColorRepresentation` with copy. Its **`Provenance`** decides the chrome, and is explicit rather than inferred because two of its three cases have no `onDelete` and the closures alone can't tell them apart: `.palette` gets the name field (the only case with somewhere to keep a name), Done, and Delete; `.derived` (a ramp swatch or a pair's mix, no palette row behind it) gets Close/Add; `.scratch` (the Color tab) gets no dismissal at all. `onAdd` is handed down from `DisplayView` to append a derived color to the palette.

Any color on screen is inspectable, however deep: `InspectedColor` + the `inspectingColor(_:colorSpace:onAdd:onEdit:)` modifier (`Shared/Views/ColorDetail/`) present a `.derived` details sheet, and the presented view applies the same modifier to *its* ramps, so the sheets just stack. `InspectedColor` carries a `UUID` because `PaletteColor`'s own `id` is its value — editing the color inside the sheet would otherwise re-present it. `onEdit` reports edits back out, which is what lets `ColorDetailsButton` — a caller-supplied label that opens the same sheet — stand in for a `ColorPicker` over a `Binding<Color>` the caller owns. Its label is generic because a swatch's shape belongs to the screen it sits on, not to the button.

`ContrastView` sits at the very bottom, under the ramps — the formats and ramps are what the color *is*, where contrast is how it behaves against something else: the color's WCAG ratio against white and against black, with text sampled both ways in each row (the ratio is symmetric, the arrangement being chosen is not). White and black are the endpoints of relative luminance — 1 and 0 — so the rows need no sampling, just `color.relativeLuminance(colorSpace:)`. The plain-language grade is `ColorMetrics.wcagGrade(_:)` (`Shared/Utilities/`), shared with the Pairs tab's readout so the two can't drift apart.

Two ramps sit below that, both resolved by `WebColorRenderer`, both draggable, and both tapping into a `.derived` `ColorDetailsView`. `ShadesView` mixes the color toward white and black in several CSS spaces. `ComplementsView` steps it around the hue wheel — a stepper picks 1–15 rotations beside the original, so `total = count + 1` colors divide the wheel evenly (2/3/4 being Complementary/Triadic/Square, which it names). It rotates via CSS relative color syntax, `oklch(from … l c calc(h + 360 * i / n))`, in the three spaces that have a hue channel: `oklab`/`lab`/`srgb` have none, and `hwb` is omitted because it shares sRGB's hue definition with `hsl` and so rotates identically. The rotation stays an exact CSS expression rather than a formatted number — `360 / 7` has no short decimal, and a locale's decimal comma would reach the CSS parser. `AddColorView` composes a new color from a picker, a dropped color, or an import — and `ColorDetailsView` replaces its color the same ways, since both share `ColorImport` (`Shared/Views/ColorDetail/`): the screen holds one `ColorImport` value, puts a `ColorImportMenu` in its toolbar, and attaches `importingColor(_:perform:)` to its *content*. The menu only chooses and the modifier owns every picker, because a presentation attached to a toolbar item isn't reliably shown. Camera (iOS), photo library, and image files all land under `ImageColorPickerView`'s eyedropper loupe; the pasteboard has nothing to present, so it finishes inside the modifier by resolving the copied text with `WebColorRenderer.resolve(_:)` — the single-color overload, which validates through `CSS.supports` because the batch one reports unparseable text as black. So anything CSS understands pastes, and bare hex digits are retried with a `#`. Every mutation path calls `onManualEdit`, so editing any color locks a perfect palette's parameters.

**CSS / P3:** PaletteKit's `cssString(...)` emits `lch()`/`lab()`/`oklch()`/`oklab()` functional notation, or `color(display-p3 ...)` when converting to P3 (gamut-mapped via ChromaKit, inside the package).

## Platform structure

- `Shared/` — all app code; cross-platform via `#if os(...)` / `#if canImport(...)` checks. `SystemColor` is typealiased to `NSColor`/`UIColor`.
- `macOS/` — macOS entitlements.
- visionOS diverges in the editor: the inspector panel sits beside the display (no `.inspector` there), and an "Open in Volume" toolbar button opens the palette's sphere in a `.volumetric` window.
