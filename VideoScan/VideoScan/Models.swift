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
//     Models/
//     ├── VideoRecord.swift            — the VideoRecord class: declaration,
//     │                                  ALL stored properties, designated init()
//     ├── VideoRecord+Codable.swift    — CodingKeys, init(from:), encode(to:)
//     ├── VideoRecord+Derived.swift    — computed/derived props (streamType,
//     │                                  sort keys, volumeName, color/health …)
//     ├── VideoRecord+Clone.swift      — snapshotClone() off-main deep copy
//     ├── MediaClassification.swift    — StreamType, PairConfidence,
//     │                                  DuplicateConfidence, DuplicateDisposition
//     ├── ArchiveModels.swift          — LifecycleStage, MediaDisposition,
//     │                                  ArchiveStage, ArchiveHealth, BackupEntry
//     ├── VolumeStatusEnums.swift      — VolumePhase, VolumeRole, VolumeTrust,
//     │                                  VolumeMediaTech, DestinationPolicy
//     ├── CatalogScanTarget.swift      — CatalogScanTarget + CatalogTargetStatus,
//     │                                  ScanPhase, VolumeProgress, ThroughputSample
//     ├── VolumeViewModels.swift       — VolumeRow, VolumeAggregate,
//     │                                  CombinePairItem, DiscoveredVolume,
//     │                                  OptionalDateComparator
//     ├── Tagging.swift                — SceneCaption, ConfirmedTag
//     └── FFProbeModels.swift          — FFProbeOutput, FFStream, FFFormat
//
// MAINTENANCE: adding a stored property to VideoRecord still means updating
// FOUR places — CodingKeys, init(from:), encode(to:) (all in
// VideoRecord+Codable.swift) and snapshotClone() (VideoRecord+Clone.swift).

import Foundation
