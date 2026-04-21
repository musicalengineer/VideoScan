# Architecture Overview

**Status:** Living document
**Last updated:** 2026-04-21
**Author:** Rick + Claude
**TL;DR:** Two-tab macOS app (People, Media) with four core files and nine supporting view files. Model files are god objects by design (deferred refactor). Settings via Cmd+,.

## App Structure

```
VideoScanApp.swift          App entry, scenes, menu commands
    |
    +-- ContentView.swift   Tab bar root (People / Media)
    |       |
    |       +-- PersonFinderView.swift     People tab
    |       |       +-- ScanJobRow.swift
    |       |       +-- PersonEditSheet.swift
    |       |       +-- RealtimeFaceDetectionWindow.swift (floating)
    |       |
    |       +-- CatalogView (in ContentView)   Media tab
    |               +-- CatalogHelpers.swift (toolbar, table, inspector, sheets)
    |
    +-- Window("Settings")
            +-- SettingsView.swift
```

## Core Files

### View Layer

| File | Lines | Responsibility |
|---|---|---|
| `ContentView.swift` | ~974 | Tab bar, CatalogView (scan targets pane, volume management, scan lifecycle) |
| `PersonFinderView.swift` | ~1,107 | People gallery, loaded faces strip, output bar, jobs section, results table |
| `ScanJobRow.swift` | ~908 | Individual scan job: collapsed/expanded views, engine settings, ring chart |
| `CatalogHelpers.swift` | ~1,356 | Catalog toolbar, content table with preview player, inspector panel, sheets |
| `PersonEditSheet.swift` | ~472 | POI profile editor: name, aliases, photos, cover crop |
| `RealtimeFaceDetectionWindow.swift` | ~673 | Floating face detection preview + console windows (AppKit hosted) |
| `SettingsView.swift` | ~293 | Performance settings: concurrency, RAM disk, engine defaults, chip info |

### Model Layer

| File | Lines | Responsibility |
|---|---|---|
| `PersonFinderModel.swift` | ~2,623 | Face recognition: reference loading, job lifecycle, scan engine dispatch, POI profiles, clip extraction |
| `VideoScanModel.swift` | ~2,491 | Catalog scanning: ffprobe, scan targets, correlate A/V pairs, combine, duplicate detection, CSV export |

### Supporting Files

| File | Purpose |
|---|---|
| `Models.swift` | Data types: VideoRecord, StreamType, CatalogScanTarget, etc. |
| `DashboardState.swift` | Shared observable state for dashboard/logging |
| `ArcFaceEngine.swift` | CoreML ArcFace face identity model |
| `CombineEngine.swift` | ffmpeg mux engine for A/V pair combining |
| `CombineSheet.swift` | Combine progress UI with pause/resume |
| `Correlator.swift` | A/V file correlation logic |
| `DuplicateDetector.swift` | Cross-volume duplicate analysis |
| `ScanEngine.swift` | Volume scanning with ffprobe |
| `ProcessRunner.swift` | Async subprocess execution |
| `AvbParser.swift` | Avid bin file parser |
| `MemoryPressure.swift` | System memory monitoring |
| `RAMDisk.swift` | RAM disk management for temp files |
| `VolumeReachability.swift` | Volume mount/unmount detection |
| `MetadataCache.swift` | Persistent ffprobe result cache |
| `PersistentLog.swift` | File-backed logging |
| `VerticalSplitView.swift` | NSSplitView wrapper for volume/catalog split |

## Key Architectural Decisions

### Two-tab layout (People / Media)
Originally three tabs (People, Media, Settings). Settings moved to Apple menu Cmd+, per macOS convention. See [settings-apple-menu.md](settings-apple-menu.md).

### Model files are god objects (intentional)
PersonFinderModel and VideoScanModel are large single classes. This is a conscious deferral — they have tightly coupled `@Published` state that makes clean extraction into extensions or helper types a larger architectural effort. The view layer was refactored first because it had clean extraction seams (self-contained structs). See [refactor-view-extraction.md](refactor-view-extraction.md) for the rationale.

### Four face detection engines
Vision (Apple native), ArcFace (CoreML on ANE), dlib (Python subprocess), Hybrid (Vision + ArcFace). Engine selection is per-job — different scan jobs can use different engines simultaneously. Dispatch happens in `processOne()` in PersonFinderModel.

### Per-job person assignment
Each scan job can target a different person. Jobs hold a copy of the POI profile + pre-loaded reference faces. Unassigned jobs fall back to the global person selection.

### Floating windows (AppKit hosted)
Face detection preview and console are floating windows managed by `NSWindowController` subclasses (`PreviewWindowController`, `JobConsoleWindowController`). They use `NSHostingView` to embed SwiftUI content. This avoids SwiftUI's window lifecycle limitations for auxiliary tool windows.

### Settings persistence
`PersonFinderSettings` uses explicit `save()` calls rather than `@AppStorage` or `didSet` observers. This is because `@Observable` (used by the model) kills `didSet`, and `@AppStorage` doesn't support complex types. A `settingsBinding` wrapper provides two-way bindings that auto-save.

## Data Flow

```
User clicks person in gallery
    -> PersonFinderView.onTapGesture
    -> model.settings.applyProfile(profile)
    -> model.loadReference()
    -> Loads photos, extracts faces via Vision
    -> model.referenceFaces populated
    -> Faces strip updates

User clicks "Find Person" -> adds ScanJob
    -> ScanJobRow appears (expanded)
    -> User picks volume/folder
    -> User clicks Start
    -> model.startJob(job)
    -> Resolves per-job settings + faces
    -> runScan() processes videos frame-by-frame
    -> Matches appear in job.results
    -> Results table updates
    -> Clips extracted via ffmpeg
```

## Test Infrastructure

- Unit tests in `VideoScanTests/` — models, correlator, duplicate detector, scan config
- UI tests in `VideoScanUITests/` — launch, basic navigation
- Test host: `main.swift` provides headless entry point for CI (no `@main` app)
- CI: GitHub Actions, macOS runner
- See [unit_tests.md](unit_tests.md) for full test documentation
