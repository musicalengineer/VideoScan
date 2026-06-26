// Models.swift
// Catalog & volume data-model overview. The ~30 model types that used to
// live here were split into the Models/ group in the 2026-06-26 model
// decomposition (step 1). Every type and member was moved VERBATIM — no
// rename, no logic change, no Codable/CodingKeys/rawValue change. The
// persisted on-disk shape is unchanged and is pinned by
// VideoScanTests/ModelSchemaTests.swift (19 tests).
//
// This file is intentionally code-free; it keeps the model-layer map in
// one canonical place that the split files point back to.
//
//     Models/   (PURE DOMAIN — Foundation-only; lifts into a Swift package)
//     ├── VideoRecord.swift            — the VideoRecord class: declaration,
//     │                                  ALL stored properties, designated init()
//     ├── VideoRecord+Codable.swift    — CodingKeys, init(from:), encode(to:)
//     ├── VideoRecord+Derived.swift    — non-UI computed/derived props
//     │                                  (streamType, sort keys, volumeName,
//     │                                  value heuristics …)
//     ├── VideoRecord+Clone.swift      — snapshotClone() off-main deep copy
//     ├── MediaClassification.swift    — StreamType, PairConfidence,
//     │                                  DuplicateConfidence, DuplicateDisposition
//     ├── ArchiveModels.swift          — LifecycleStage, MediaDisposition,
//     │                                  ArchiveStage, BackupEntry
//     ├── VolumeStatusEnums.swift      — VolumePhase, VolumeRole, VolumeTrust,
//     │                                  VolumeMediaTech
//     ├── Tagging.swift                — SceneCaption, ConfirmedTag
//     └── FFProbeModels.swift          — FFProbeOutput, FFStream, FFFormat
//
//     ModelsUI/ (APP-SIDE — imports SwiftUI/Combine; the display layer)
//     ├── MediaClassification+Presentation.swift — Color accessors
//     ├── ArchiveModels+Presentation.swift       — icon/Color accessors
//     ├── ArchiveHealth.swift                    — ArchiveHealth (UI-only)
//     ├── VolumeStatusEnums+Presentation.swift   — icon/Color/shortLabel
//     ├── DestinationPolicy.swift                — DestinationPolicy (UI-only)
//     ├── VideoRecord+Presentation.swift         — filenameColor, rowColor,
//     │                                            archiveHealth
//     ├── CatalogScanTarget.swift      — CatalogScanTarget + CatalogTargetStatus,
//     │                                  ScanPhase, VolumeProgress, ThroughputSample
//     └── VolumeViewModels.swift       — VolumeRow, VolumeAggregate,
//                                        CombinePairItem, DiscoveredVolume,
//                                        OptionalDateComparator
//
// MAINTENANCE: adding a stored property to VideoRecord still means updating
// FOUR places — CodingKeys, init(from:), encode(to:) (all in
// VideoRecord+Codable.swift) and snapshotClone() (VideoRecord+Clone.swift).

import Foundation
