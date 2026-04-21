# View Extraction Refactor

**Status:** Shipped (phase 1 complete)
**Last updated:** 2026-04-21
**Author:** Rick + Claude
**TL;DR:** Extracted 5 focused view files from two 2000+ line god objects. PersonFinderView dropped 65%, ContentView dropped 58%. Model files intentionally left alone.

## Motivation

Four files had grown too large for comfortable navigation and review:

| File | Lines (before) | Role |
|---|---|---|
| `PersonFinderView.swift` | 3,144 | Person finder UI: gallery, faces strip, jobs, results, edit sheets, windows |
| `ContentView.swift` | 2,326 | Tab bar, catalog view, toolbar, table, inspector, discover volumes |
| `PersonFinderModel.swift` | 2,623 | Face recognition engine, job lifecycle, reference loading, POI profiles |
| `VideoScanModel.swift` | 2,491 | Scan engine, ffprobe, correlate, combine, duplicates, CSV |

Rick asked for "cleanest code possible" with incremental extraction and tests between each step.

## What Was Extracted

### From PersonFinderView.swift (3,144 -> 1,107 lines)

| New File | Lines | Contents |
|---|---|---|
| `RealtimeFaceDetectionWindow.swift` | 673 | LiveFramePreview, RealtimeFaceDetectionContent, ActiveJobFaceDetectView, FaceDetectHUD, FaceDetectLegend, PreviewWindowController, JobConsoleContent, JobConsoleBody, JobConsoleWindowController, `formatElapsed()` |
| `PersonEditSheet.swift` | 472 | PersonEditSheet (name/aliases/notes/photos/cover crop), CroppedCircleImage, CoverCropEditor, photo import logic (Apple Photos + file browser) |
| `ScanJobRow.swift` | 908 | ScanJobRow (collapsed/expanded), LabeledControl, RecognitionEnginePanel, ScanRingChart, `Binding<Float>.asDouble` extension |

**What remains in PersonFinderView.swift:** PersonFinderView (main view), peopleGallery, loadedFacesStrip, outputBar, jobsSection, resultsTable, result info popover, face detail popover, helper methods, ReferenceFaceCard, PersonCard, CompactFaceThumbnail, ScanTargetPOIBadge, SpinningRing.

### From ContentView.swift (2,326 -> 974 lines)

| New File | Lines | Contents |
|---|---|---|
| `SettingsView.swift` | 293 | SettingsTabView with chip info, performance settings, GPU detection |
| `CatalogHelpers.swift` | 1,356 | CatalogToolbar, CatalogContent (table + preview + inspector), RenameSheet, InspectorPanel, DuplicateDispositionCell, DiscoverVolumesSheet |

**What remains in ContentView.swift:** ContentView (tab bar root), VolumeFilter enum, CatalogView (scan targets pane, volume management, scan lifecycle).

## What Was NOT Extracted (and Why)

### Model files (PersonFinderModel, VideoScanModel)

These are single `@MainActor final class` definitions with tightly coupled `@Published` stored properties. Extracting methods into extension files in separate Swift files means:

1. **Stored properties can't live in extensions.** Constants like `private let durationTolerance` must stay in the main class body.
2. **`private` access breaks across files.** Swift allows `private` member access from same-file extensions only. Moving methods to a separate file requires changing `private` to `internal`, which weakens encapsulation for no functional benefit in a single-module app.
3. **Risk/reward ratio is poor.** The view extractions were clean seams (self-contained structs moved wholesale). Model methods are interleaved with state — higher regression risk, lower readability payoff.

**Recommendation for future refactoring:** If the model files grow further, consider:
- Extract pure-logic helpers into standalone structs/functions (e.g., `CorrelationEngine`, `DuplicateAnalyzer`) that take data in and return results out, rather than operating on `self`.
- Keep the `@Published` state management thin — the model becomes a coordinator that delegates to engines.
- This is a bigger architectural change, not a file-move refactor.

## Extraction Pattern Used

Each extraction followed the same steps:

1. **Read the source file** — identify the struct/view to extract, its boundaries, and its dependencies (imports, types, access levels).
2. **Create the new file** — copy the code, add required imports, change `private struct` to `struct` (internal access).
3. **Remove from source** — delete the extracted code from the original file. This was the trickiest step; orphaned code fragments were a recurring issue.
4. **Build** — verify compilation succeeds with `xcodebuild -configuration Release`.
5. **Test** — run full unit + UI test suite in Debug configuration.
6. **Commit** — only after green tests.

## Gotchas Encountered

- **`private` -> `internal`:** All extracted structs were `private` in ContentView.swift. They needed to become `internal` (default) when moved to their own files so the original file could still reference them.
- **Transitive imports:** `import PhotosUI` was pulling in `UniformTypeIdentifiers`. After removing PhotosUI from PersonFinderView.swift (it moved with PersonEditSheet), we had to add `import UniformTypeIdentifiers` explicitly for `NSOpenPanel.allowedContentTypes = [.plainText]`.
- **`formatElapsed()` shared function:** Was `private` in PersonFinderView.swift but used by both PersonFinderView and RealtimeFaceDetectionWindow. Made it a module-level `func` (internal) in RealtimeFaceDetectionWindow.swift.
- **Orphaned code after removal:** Multiple attempts to remove extracted code left partial fragments. Using `head -n N file > tmp && mv tmp file` (truncation) was more reliable than trying to match and delete specific ranges with the Edit tool.

## File Inventory After Refactor

| File | Lines | Responsibility |
|---|---|---|
| `ContentView.swift` | 974 | Tab bar, CatalogView (scan targets, volume management) |
| `PersonFinderView.swift` | 1,107 | Person finder main UI (gallery, faces, jobs list, results) |
| `PersonFinderModel.swift` | 2,623 | Face recognition engine, job lifecycle, POI profiles |
| `VideoScanModel.swift` | 2,491 | Catalog scan engine, ffprobe, correlate, combine, duplicates |
| `SettingsView.swift` | 293 | App settings panel (Cmd+,) |
| `RealtimeFaceDetectionWindow.swift` | 673 | Floating face detection + console windows |
| `PersonEditSheet.swift` | 472 | POI profile editor with photo management |
| `ScanJobRow.swift` | 908 | Individual scan job row with engine settings |
| `CatalogHelpers.swift` | 1,356 | Catalog toolbar, table, inspector, sheets |
