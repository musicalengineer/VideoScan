// VolumeContextMenuRules.swift
// The yes/no decisions the volume context menu's Catalog section makes,
// as pure functions over the selection and the records, so the
// @ViewBuilder in CatalogView+VolumeTable.swift only lays items out.
// Split out of CatalogView.volumeContextCatalogSection (2026-10-10); each
// rule is named for WHAT it decides and is tested on its own
// (VolumeContextMenuRulesTests).
//
// Known cost, deliberately unchanged tonight: `captionableVideoCount` and
// `offersVolumeNameBackfill` walk `model.records` while the menu is being
// built — swift_playbook §2's "Worst" example. Moving them onto the
// per-target counts VolumeStatusCache keeps is the GH #104 fix template.

import Foundation

enum VolumeContextMenuRules {

    /// Videos under `searchPath` the VLM captioner would visit: records
    /// with a video stream (with or without sound). Plain prefix match on
    /// the path, exactly as the menu always counted.
    static func captionableVideoCount(records: [VideoRecord], under searchPath: String) -> Int {
        records.filter { r in
            r.fullPath.hasPrefix(searchPath) &&
            (r.streamType == .videoAndAudio || r.streamType == .videoOnly)
        }.count
    }

    /// Show Migrated… applies only to a disk that is gone or parked: an
    /// online volume's files ARE the online version, so the report would
    /// be noise there.
    static func offersMigrationReport(isRetired: Bool, isReachable: Bool) -> Bool {
        isRetired || !isReachable
    }

    /// Backfill All Volume Names: several volumes selected, or one whose
    /// records include some that never recorded a volume name.
    static func offersVolumeNameBackfill(targetCount: Int, records: [VideoRecord]) -> Bool {
        targetCount > 1 || (targetCount == 1 && records.contains(where: { $0.scanContext.volumeName.isEmpty }))
    }

    /// Reset & Re-probe: at least one selected target has finished its
    /// scan, one way or another.
    static func offersReset(statuses: [CatalogTargetStatus]) -> Bool {
        statuses.contains { $0 == .complete || $0 == .stopped || $0 == .error }
    }
}
