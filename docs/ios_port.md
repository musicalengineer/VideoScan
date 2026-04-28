# iOS / iPadOS Port — Preliminary Plan

**Status:** Exploratory. Low priority — captured so the architecture choices we make on the Mac side don't paint us into a corner.

**Scope of the iOS app:** *browse and edit*, not scan. The Mac stays the heavy-lifting surface; the iPad is the "show grandkids on the couch / casually tag photos" surface.

---

## What the iOS app does

- Imports a `.videoscanbundle` exported from the Mac (via Files / iCloud Drive / AirDrop).
- Browses the catalog: sortable list, filter chips (volume, decade, stream type), search, per-record metadata.
- Browses the People gallery and reference photos.
- Edits POIs: rename, change cover, add/remove reference photos, edit notes/aliases.
- Exports a modified bundle back to Files / iCloud Drive so the Mac can re-import.

## What the iOS app deliberately does **not** do

- No scanning. No `Process`/ffmpeg/ffprobe. No catalog mutation.
- No face recognition runs. (Vision/CoreML can technically run on iOS, but recognition is a Mac-side workflow that produces clips — iPad just views the catalog.)
- No volume metadata editing. iPad has no concept of mounted volumes.
- No PersonFinderSettings UI. Those settings only matter when you run a scan.

This keeps the iOS surface area small enough that one person can ship it.

---

## Why this is feasible

The bundle format from `BundleExportImport.swift` is the pivot point. It's already a complete portable representation of the user's world. The iPad just needs to read one, render it, and (in v2+) write a modified one back.

Most of the actual code is platform-agnostic Foundation:

| File | Portable as-is |
|---|---|
| `Models.swift` (record/enum types, computed policy) | Yes, modulo `@MainActor` placements |
| `BundleExportImport.swift` | Yes (already pure Foundation) |
| `POIStorage.swift` | Yes — Application Support exists on iOS too |
| `CatalogStore.swift` | Yes |
| `PersonFinderSettings` (struct + UserDefaults) | Yes (we just won't expose UI) |
| ArcFace / Vision wrappers | Yes (not used on iPad initially) |

The AppKit-only pieces are concentrated and tractable:

| AppKit thing | iOS replacement |
|---|---|
| `NSOpenPanel` / `NSSavePanel` | `UIDocumentPickerViewController` |
| `NSAlert` | SwiftUI `.alert(...)` |
| `HSplitView` | `NavigationSplitView` (iPadOS 16+) |
| Right-click `.contextMenu` | Same modifier, long-press gesture |
| `NSWindow` plumbing | Multi-scene `WindowGroup` |
| `NSWorkspace` mount notifications | Not needed (no volumes on iPad) |

---

## Architecture

### Step 0 — extract a Swift Package: `VideoScanCore`

Pull the platform-agnostic types out of the Xcode project into a Swift Package living at `VideoScan/Packages/VideoScanCore/`. Mac app imports the package and removes the duplicated source files.

Initial package contents:
```
VideoScanCore/
├── Sources/VideoScanCore/
│   ├── Models/
│   │   ├── VideoRecord.swift
│   │   ├── VolumeRole.swift
│   │   ├── VolumeTrust.swift
│   │   ├── VolumeMediaTech.swift
│   │   └── VolumePhase.swift
│   ├── Storage/
│   │   ├── CatalogStore.swift
│   │   ├── CatalogSnapshot.swift
│   │   ├── POIStorage.swift
│   │   └── POIProfile.swift
│   ├── Bundle/
│   │   └── BundleExportImport.swift
│   └── Settings/
│       └── PersonFinderSettings.swift
└── Tests/VideoScanCoreTests/
    └── (existing pure-logic tests move here)
```

Mac target's `Package.swift`-style dependency, no behavioral change. This is the largest single piece of work — but it's also the one piece of work that pays off even if we never ship the iOS app, because it disciplines the layering.

### Step 1 — iOS target

New target inside the existing Xcode project (or a separate project — TBD), `import VideoScanCore`, plus iOS-specific UI:

```
VideoScanIOS/
├── VideoScanIOSApp.swift          // @main, SceneDelegate
├── Browse/
│   ├── CatalogBrowseView.swift    // record list, filter, search
│   └── RecordDetailView.swift     // per-record metadata sheet
├── People/
│   ├── PeopleGalleryView.swift    // read-only grid (Phase 1)
│   ├── PersonEditView.swift       // notes, cover crop, photo add/remove (Phase 2)
│   └── PhotoPickerSheet.swift     // PhotosPicker integration
└── Bundle/
    ├── BundleImportView.swift     // DocumentPicker entry, progress
    └── BundleExportView.swift     // write back to Files/iCloud Drive
```

### Read-only catalog on iOS — design call

`VideoRecord` is a heavy `ObservableObject` class because the Mac mutates it mid-scan (paired-with rewiring, sourceHost stamping, etc.). iPad never mutates records — it just displays them.

**Option A (recommended): share `VideoRecord` from `VideoScanCore`, treat it as read-only on iOS.** Decode once from `catalog.json`, hold in an array, render. The class stays Codable; the `@MainActor` annotation is fine on iOS too.

**Option B:** Define a parallel `IosVideoRecord` struct on the iOS side that decodes the same JSON. Cleaner separation but doubles the maintenance.

Lean toward A unless we hit concrete pain.

---

## Phased plan

| Phase | Deliverable | Approximate effort |
|---|---|---|
| **0** | Extract `VideoScanCore` Swift Package; Mac app builds against it; existing tests pass | ~1 day |
| **1** | iOS target, bundle import via DocumentPicker, catalog browse, people gallery (read-only). Side-load to iPad, kick the tires. | ~2–3 days |
| **2** | Person editing: rename, notes, aliases, cover crop, add/remove reference photos from iOS Photos library | ~1–2 days |
| **3** | Export edited bundle back to Files / iCloud Drive; Mac re-imports normally; full round-trip works | ~half day |
| **4** *(optional polish)* | iOS Photos share-sheet extension: "Save to VideoScan POI" without opening the app | ~1 day |

Phase 0 alone is worth doing even if iOS never ships.

---

## Sync model

For v1: **bundle as the sync unit.** Mac exports → user moves the bundle to iPad (AirDrop or iCloud Drive folder, the user's choice) → iPad imports. iPad edits POIs → exports a new bundle → user moves it back → Mac imports. Bundle import on the Mac already overwrites POIs wholesale, so the round-trip works without any new merge logic.

For v1.5 (if it feels worth it): **shared iCloud Drive folder.** Both Mac and iPad read/write `~/Library/Mobile Documents/com~apple~CloudDocs/VideoScan/current.videoscanbundle/`. macOS auto-syncs that path with no entitlement; iOS reads/writes via DocumentPicker scoped to the same folder. Last-writer-wins is fine for personal use.

For v2 (probably not worth it): CloudKit. Real-time sync, but pulls in the Developer Program enrollment Rick is reluctant about, plus a meaningful schema migration of the catalog.

---

## Distribution

- **Free side-load** (personal Apple ID): works for Rick's own iPad. Provisioning re-signs every 7 days; not a problem for a tool you build yourself.
- **Developer Program ($99/yr):** enables TestFlight (sons could install) and App Store. Not required for "just my iPad."

Plan should not assume Developer Program. If we ever go there, it's strictly additive.

---

## Open questions

1. **One Xcode project or two?** Keep iOS target inside `VideoScan.xcodeproj` (shared package, single source tree, two schemes) or separate `VideoScanIOS.xcodeproj` consuming the package as a path dependency? Single project is simpler; two projects keeps the macOS build immune to iOS-side breakage.
2. **`VideoRecord` class vs. struct?** Right now it's a class because of paired-with back-references. If we ever flatten that (store paired-with as IDs, resolve at render time), `VideoRecord` becomes a `struct` and a lot of `@MainActor`/`ObservableObject` complexity falls away on both platforms.
3. **iPad UI scale.** The macOS app assumes a 1440+ pt window. iPad is 768–1366 pt. The People gallery and catalog table need a compact layout pass.
4. **Photos share extension.** The "Send to VideoScan" share-sheet idea is genuinely cool but it's a separate target with its own provisioning. Defer until Phase 4 unless it turns out to be the killer feature.

---

## Architectural decisions that make this easier *on the Mac side now*

These are zero-cost or near-zero-cost moves we should keep in mind even if iOS never ships:

- Keep `BundleExportImport.swift` pure Foundation. (Already true.)
- Avoid putting `AppKit` imports inside types that live in `Models.swift`, `CatalogStore.swift`, `POIStorage.swift`, `BundleExportImport.swift`. (Mostly already true; verify before each commit.)
- When extending the bundle format, treat `manifest.bundleVersion` as a real version number — bump it on incompatible changes so the iOS importer can reject newer bundles cleanly. (Already wired.)
- POI folder layout (`~/Library/Application Support/VideoScan/POI/<name>/`) is already iOS-compatible. Don't drift from "self-contained POI folder" — that's the property that makes the iPad story work.
