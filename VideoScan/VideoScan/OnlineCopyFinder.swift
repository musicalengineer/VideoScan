import Foundation

// MARK: - OnlineCopyFinder
//
// Same-content lookup behind two catalog verbs (Rick 2026-06-11):
//
//   - "Find Online Version" — right-click an offline record, jump the
//     catalog view to a copy that's on a mounted volume right now.
//   - "Show Migrated…" — right-click an offline/retired volume, report
//     whether every record on it has a copy elsewhere, and where.
//
// "Same content" is deliberately stricter than DuplicateDetector's
// scored fuzzy match — these verbs answer "where is THIS file", so a
// wrong answer is worse than no answer. A record qualifies as a copy
// when any of:
//
//   1. partialMD5 + sizeBytes both match (both hashes non-empty) — the
//      catalog's strong identity key.
//   2. materialPackageUMID matches AND streamType matches (Avid MXF:
//      the audio and video files of one clip share the material
//      package UMID, so the streamType guard stops a video-only file
//      "finding" its audio sibling).
//   3. duplicateGroupID matches — trust a completed duplicate scan's
//      verdict (its keys already include streamType).
//
// Purged records never participate, on either side of the match.
//
// Pure logic — no Process, no disk, no VolumeReachability. Callers
// inject `isOnline` / `volumeLabel` closures, which keeps every path
// here unit-testable (and keeps the one-pass index build measurable:
// O(n) over ~16k records, a few ms).

struct OnlineCopyFinder {

    private let active: [VideoRecord]
    private let byHashSize: [String: [VideoRecord]]
    private let byUMID: [String: [VideoRecord]]
    private let byDupGroup: [UUID: [VideoRecord]]

    init(records: [VideoRecord]) {
        let active = records.filter { !$0.isPurged }
        self.active = active
        byHashSize = Dictionary(grouping: active.filter { !$0.partialMD5.isEmpty }) {
            Self.hashSizeKey($0)
        }
        byUMID = Dictionary(grouping: active.filter { !$0.materialPackageUMID.isEmpty }) {
            Self.umidKey($0)
        }
        byDupGroup = Dictionary(grouping: active.filter { $0.duplicateGroupID != nil }) {
            $0.duplicateGroupID!
        }
    }

    private static func hashSizeKey(_ r: VideoRecord) -> String {
        "\(r.partialMD5)|\(r.sizeBytes)"
    }

    private static func umidKey(_ r: VideoRecord) -> String {
        "\(r.materialPackageUMID)|\(r.streamTypeRaw)"
    }

    // MARK: Per-record copies

    /// Every other active record with the same content, hash-key
    /// matches first (strongest evidence), then UMID, then dup-group;
    /// deduped by id, stable within each tier by path.
    func sameContentCopies(of rec: VideoRecord) -> [VideoRecord] {
        guard !rec.isPurged else { return [] }
        var seen: Set<UUID> = [rec.id]
        var out: [VideoRecord] = []

        var tiers: [[VideoRecord]] = []
        if !rec.partialMD5.isEmpty {
            tiers.append(byHashSize[Self.hashSizeKey(rec)] ?? [])
        }
        if !rec.materialPackageUMID.isEmpty {
            tiers.append(byUMID[Self.umidKey(rec)] ?? [])
        }
        if let group = rec.duplicateGroupID {
            tiers.append(byDupGroup[group] ?? [])
        }
        for tier in tiers {
            for other in tier.sorted(by: { $0.fullPath < $1.fullPath })
            where seen.insert(other.id).inserted {
                out.append(other)
            }
        }
        return out
    }

    // MARK: Volume migration report

    struct MigrationReport: Equatable {
        /// Active records living on the queried volume.
        let total: Int
        /// Of those, how many have at least one copy on a DIFFERENT
        /// volume (online or not — "it exists somewhere else").
        let migrated: Int
        /// Of the migrated, how many have a copy that is mounted right
        /// now (the "usable today" number).
        let migratedOnlineNow: Int
        /// Where the copies live: volume label → record count (each
        /// source record counted once per destination volume), with the
        /// destination's current reachability. Sorted online-first,
        /// then by count descending.
        let destinations: [Destination]
        /// Records with NO copy anywhere else — the migration gap.
        let unmigratedIDs: [UUID]

        struct Destination: Equatable {
            let volumeLabel: String
            let recordCount: Int
            let isOnline: Bool
        }

        var isFullyMigrated: Bool { total > 0 && migrated == total }
    }

    /// Build the report for one volume. `volumePathPrefix` is the scan
    /// target's searchPath (records belong to it by path prefix — the
    /// same rule ContentView's volume highlight uses).
    func migrationReport(volumePathPrefix: String,
                         isOnline: (String) -> Bool,
                         volumeLabel: (String) -> String) -> MigrationReport {
        let onVolume = active.filter { $0.fullPath.hasPrefix(volumePathPrefix) }

        var migrated = 0
        var migratedOnlineNow = 0
        var unmigratedIDs: [UUID] = []
        // label → (count, isOnline) — reachability per label resolved once.
        var destCounts: [String: Int] = [:]
        var destOnline: [String: Bool] = [:]

        for rec in onVolume {
            let elsewhere = sameContentCopies(of: rec)
                .filter { !$0.fullPath.hasPrefix(volumePathPrefix) }
            if elsewhere.isEmpty {
                unmigratedIDs.append(rec.id)
                continue
            }
            migrated += 1
            var anyOnline = false
            var labelsForThisRecord: Set<String> = []
            for copy in elsewhere {
                let label = volumeLabel(copy.fullPath)
                if labelsForThisRecord.insert(label).inserted {
                    destCounts[label, default: 0] += 1
                }
                if destOnline[label] == nil {
                    destOnline[label] = isOnline(copy.fullPath)
                }
                if destOnline[label] == true { anyOnline = true }
            }
            if anyOnline { migratedOnlineNow += 1 }
        }

        let destinations = destCounts
            .map { MigrationReport.Destination(volumeLabel: $0.key,
                                               recordCount: $0.value,
                                               isOnline: destOnline[$0.key] ?? false) }
            .sorted {
                if $0.isOnline != $1.isOnline { return $0.isOnline }
                if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
                return $0.volumeLabel < $1.volumeLabel
            }

        return MigrationReport(total: onVolume.count,
                               migrated: migrated,
                               migratedOnlineNow: migratedOnlineNow,
                               destinations: destinations,
                               unmigratedIDs: unmigratedIDs)
    }
}
