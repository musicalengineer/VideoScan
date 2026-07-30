// Models.swift
// Catalog & volume data-model overview. The ~30 model types that used to
// live here were split into the Models/ group in the 2026-06-26 model
// decomposition (step 1), the UI accessors lifted into ModelsUI/ (step 2),
// and the PURE DOMAIN files then EXTRACTED into the VideoScanCore Swift
// package (step 3, 2026-06-26). Every type and member moved VERBATIM — no
// rename, no logic change, no Codable/CodingKeys/rawValue change. The only
// edit at extraction was widening access to `public` so the app target can
// see the package's types (the app sees them transparently via
// `@_exported import VideoScanCore` in VideoScanCoreExports.swift — no
// per-file import needed). The persisted on-disk shape is unchanged and is
// pinned by BOTH VideoScanTests/ModelSchemaTests.swift (validates the public
// API through @_exported) AND the package's own
// VideoScanCoreTests/VideoScanCoreModelTests.swift (validates the package in
// isolation via a plain `import VideoScanCore`).
//
// This file is intentionally code-free; it keeps the model-layer map in
// one canonical place that the split files point back to. The old Models/
// app subdirectory is gone — its files now live in the package.
//
//     VideoScanCore/Sources/VideoScanCore/   (PURE DOMAIN — Foundation-only
//                                             Swift package; compiles + tests
//                                             with ZERO app/SwiftUI deps)
//     ├── VideoRecord.swift            — the VideoRecord class: declaration,
//     │                                  ALL stored properties, designated init(),
//     │                                  required init(from:)
//     ├── VideoRecord+Codable.swift    — CodingKeys, encode(to:)
//     ├── VideoRecord+Derived.swift    — non-UI computed/derived props
//     │                                  (streamType, sort keys, value
//     │                                  heuristics, isLikelyUnanalyzable …).
//     │                                  NOTE: volumeName / displayVolumeLabel
//     │                                  did NOT follow — see ModelsUI below.
//     ├── VideoRecord+Clone.swift      — snapshotClone() off-main deep copy
//     ├── MediaClassification.swift    — StreamType, PairConfidence,
//     │                                  DuplicateConfidence, DuplicateDisposition
//     ├── ArchiveModels.swift          — LifecycleStage, MediaDisposition,
//     │                                  ArchiveStage, BackupEntry
//     ├── VolumeStatusEnums.swift      — VolumePhase, VolumeRole, VolumeTrust,
//     │                                  VolumeMediaTech
//     ├── Tagging.swift                — SceneCaption, ConfirmedTag
//     ├── FFProbeModels.swift          — FFProbeOutput, FFStream, FFFormat
//     ├── UnplayableLegacyCodecs.swift — legacy-codec playability + the
//     │                                  analyze-value heuristic (domain logic)
//     └── ScanContext.swift            — ScanContext struct + Codable +
//                                        subfolderLabel(forScanRootPath:).
//                                        The capture(for:) FACTORY stayed
//                                        app-side — see ModelsUI below.
//
//     ModelsUI/ (APP-SIDE — imports SwiftUI/Combine + app infra; display layer
//               and the few derivations that depend on VolumeReachability /
//               CatalogHost, which can't follow into the pure package)
//     ├── MediaClassification+Presentation.swift — Color accessors
//     ├── ArchiveModels+Presentation.swift       — icon/Color accessors
//     ├── ArchiveHealth.swift                    — ArchiveHealth (UI-only)
//     ├── VolumeStatusEnums+Presentation.swift   — icon/Color/shortLabel
//     ├── DestinationPolicy.swift                — DestinationPolicy (UI-only)
//     ├── VideoRecord+Presentation.swift         — filenameColor, rowColor,
//     │                                            archiveHealth
//     ├── VideoRecord+DerivedApp.swift — volumeName / displayVolumeLabel
//     │                                  (depend on VolumeReachability)
//     ├── ScanContext+Capture.swift    — ScanContext.capture(for:scanRootPath:)
//     │                                  (depends on CatalogHost +
//     │                                  VolumeReachability.mountInfo)
//     ├── CatalogScanTarget.swift      — CatalogScanTarget + CatalogTargetStatus,
//     │                                  ScanPhase, VolumeProgress, ThroughputSample
//     └── VolumeViewModels.swift       — VolumeRow, VolumeAggregate,
//                                        CombinePairItem, OptionalDateComparator
//
// MAINTENANCE: adding a stored property to VideoRecord still means updating
// FOUR places — CodingKeys, encode(to:) (both in VideoRecord+Codable.swift),
// init(from:) (in VideoRecord.swift), and snapshotClone()
// (VideoRecord+Clone.swift) — now all inside the VideoScanCore package.
//
import Foundation
