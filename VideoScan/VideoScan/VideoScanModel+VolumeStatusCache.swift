// VideoScanModel+VolumeStatusCache.swift
// Per-volume retire-status cache — the 2026-07-05 Volumes-window
// beachball fix.
//
// The Volumes window used to compute retire readiness inside its body:
// `retireStatus(for:)` made FOUR full-catalog sweeps per volume row
// (totalRecordsOn / manuallyDeletedOn / originatedOnCount /
// aggregateRetiredWitnesses), each running PathScope normalization per
// record. At 103k records × ~19 targets that's ~8M path comparisons per
// body evaluation — and a keystroke in the notes field invalidates the
// body. A 20 s main-thread sample during typing put 91% of samples in
// that chain (PathScope.normalize alone was the hottest frame in the app).
//
// The fix follows the dossierCounts discipline ("NO O(records) work in
// view bodies"): ONE background pass over a value snapshot of the catalog
// computes every volume's status simultaneously, then publishes a
// dictionary on the main actor. Rows read the dictionary — O(1).
//
// Threading: the aggregator is `@concurrent` — in this repo a plain
// `nonisolated async` helper runs on the CALLER's actor (see
// project_approachable_concurrency_trap), so @concurrent is what actually
// moves the work off @MainActor. The snapshot is taken ON the main actor
// (cheap field reads), so the off-main pass touches only Sendable values,
// never live VideoRecord instances.

import Foundation

// MARK: - Retire-readiness status

/// Per-volume readiness signal, computed by the model's status cache from
/// records + scan targets. Drives the Volumes window badge + menu state.
/// (Moved here from VolumesWindow.swift 2026-07-05 — the model owns the
/// computation now, the view only reads.)
struct VolumeRetireStatus: Equatable {
    let totalRecords: Int
    let disposedRecords: Int
    let allDisposed: Bool
    let hasSafeWitness: Bool

    /// Fail-safe placeholder for a cache miss (cache still warming up):
    /// zero records, `canRetire` false — a cold cache can never enable
    /// a destructive action.
    static let empty = VolumeRetireStatus(
        totalRecords: 0, disposedRecords: 0,
        allDisposed: false, hasSafeWitness: false
    )

    /// "Safe to retire" — every record is disposed AND there's a safe
    /// witness backing up the contents. Matches Rick's description of
    /// the green-pill state.
    var isSafeToRetire: Bool { allDisposed && hasSafeWitness }

    /// "Disposed but degraded" — every record disposed, but no safe
    /// witness yet. Yellow-pill state.
    var isDegradedDisposed: Bool { allDisposed && !hasSafeWitness }

    /// Predicate gating the Mark Retired action. We require BOTH 100%
    /// disposed AND at least one safe witness — otherwise the user could
    /// retire a drive whose only backup is on another retiring drive,
    /// which is exactly the regression Rick called out.
    var canRetire: Bool { isSafeToRetire }

    /// Tooltip shown on the disabled Mark Retired menu item. Tells the
    /// user what's missing without making them guess.
    var tooltipForRetireAction: String {
        if totalRecords == 0 {
            return "No catalogued files on this volume yet."
        }
        if !allDisposed {
            return "Not all files on this volume are accounted for yet — run Migrate first."
        }
        if !hasSafeWitness {
            return "Files are marked disposed, but no backup copies are confirmed on safer drives."
        }
        return "Mark this volume retired."
    }
}

// MARK: - Sendable snapshots (main-actor reads → off-main compute)

/// The five record fields the aggregator needs, captured as values on the
/// main actor. `notes` is only kept for `.manuallyDeleted` records (the
/// only ones whose witness lines are parsed) so the snapshot stays lean
/// even on 100k+ catalogs.
struct VolumeStatusRecordSnap: Sendable {
    let fullPath: String
    let isManuallyDeleted: Bool
    let originVolume: String?
    let originalFullPath: String?
    let notes: String?
}

/// Scan-target identity + safety fields, captured as values.
struct VolumeStatusTargetSnap: Sendable {
    let searchPath: String
    let role: VolumeRole
    let trust: VolumeTrust
    /// `CatalogScanTarget.isRetired` — retirement is a lifecycle event,
    /// not a role, so it is snapshotted separately (taxonomy 2026-08-16).
    var isRetired: Bool = false
}

extension VideoScanModel {

    // MARK: - Invalidation (debounced, coalescing)

    /// Mark the per-volume status cache stale. Cheap enough to call from
    /// per-record loops — coalesces any burst of mutations into ONE
    /// background rebuild 300 ms later. Mirrors
    /// `noteCatalogChangedForDossierCounts`.
    func noteVolumeStatusesStale() {
        volumeStatusGeneration &+= 1
        guard !volumeStatusRefreshScheduled else { return }
        volumeStatusRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.volumeStatusRefreshScheduled = false
            await self.rebuildVolumeStatusesNow()
        }
    }

    /// Snapshot on the main actor, aggregate off it, publish back on it.
    /// Public so tests can await a deterministic rebuild without the
    /// debounce. A rebuild that loses a generation race (a newer
    /// invalidation arrived while it was computing) publishes nothing —
    /// the newer scheduled rebuild owns the result.
    func rebuildVolumeStatusesNow() async {
        countVolumeStatusRecompute()
        let generation = volumeStatusGeneration
        // Value snapshot — cheap field reads on the main actor, O(records).
        let recordSnaps = records.map { r in
            VolumeStatusRecordSnap(
                fullPath: r.fullPath,
                isManuallyDeleted: r.archiveStage == .manuallyDeleted,
                originVolume: r.originVolume,
                originalFullPath: r.originalFullPath,
                notes: r.archiveStage == .manuallyDeleted ? r.notes : nil
            )
        }
        let targetSnaps = scanTargets
            .filter { !$0.searchPath.isEmpty }
            .map { VolumeStatusTargetSnap(searchPath: $0.searchPath,
                                          role: $0.role,
                                          trust: $0.trust,
                                          isRetired: $0.isRetired) }
        // Heavy string work happens OFF the main actor.
        let fresh = await Self.computeVolumeStatuses(records: recordSnaps,
                                                     targets: targetSnaps)
        // Stale-generation guard: a newer invalidation owns the cache.
        guard generation == volumeStatusGeneration else { return }
        publishVolumeStatuses(fresh)
    }

    // MARK: - Single-pass aggregator (pure, off-main)

    /// Compute every volume's retire status in ONE pass over the record
    /// snapshots. Semantics are identical to the four legacy per-volume
    /// sweeps (totalRecordsOn / manuallyDeletedOn / originatedOnCount /
    /// aggregateRetiredWitnesses + the safe-migrated-destination check) —
    /// VolumeStatusCacheTests pins the parity. Nested roots (a record
    /// under both `/Volumes/X` and a hypothetical broader target) count
    /// toward EVERY matching root, exactly like the legacy per-root scans.
    ///
    /// Cost: records × targets prefix checks on pre-normalized strings
    /// (~2M memcmp for 103k × 19 — tens of ms on a background core).
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable` and warns;
    // pre-6.2 a nonisolated async already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func computeVolumeStatuses(
        records: [VolumeStatusRecordSnap],
        targets: [VolumeStatusTargetSnap]
    ) async -> [String: VolumeRetireStatus] {
        guard !targets.isEmpty else { return [:] }

        // Pre-normalize every root ONCE (the legacy path re-normalized
        // per record — the single hottest frame in the beachball sample).
        struct Root {
            let key: String          // normalized searchPath (cache key)
            let slashed: String      // key + "/" for prefix tests
            let name: String         // trailing component (originVolume match)
            let originPrefix: String // legacy originatedOnCount prefix form
        }
        let roots: [Root] = targets.map { t in
            let key = PathScope.normalize(t.searchPath)
            return Root(
                key: key,
                slashed: key == "/" ? "/" : key + "/",
                name: (t.searchPath as NSString).lastPathComponent,
                // Legacy originatedOnCount used the RAW searchPath +
                // trailing slash — preserve exactly.
                originPrefix: t.searchPath.hasSuffix("/")
                    ? t.searchPath : t.searchPath + "/"
            )
        }
        // Safe-witness resolver over the target snapshots — same
        // longest-prefix-wins contract as makeVolumeSafetyResolver().
        let sortedForResolve = targets
            .map { (path: $0.searchPath, safety: VolumeSafety(role: $0.role, trust: $0.trust, isRetired: $0.isRetired)) }
            .sorted { $0.path.count > $1.path.count }
        func resolve(_ path: String) -> VolumeSafety {
            for e in sortedForResolve where path.hasPrefix(e.path + "/")
                                         || path == e.path {
                return e.safety
            }
            return VolumeSafety.unknown
        }
        func isSafe(_ path: String) -> Bool {
            resolve(path).isSafe
        }

        // Per-root accumulators, index-aligned with `roots`.
        var total = [Int](repeating: 0, count: roots.count)
        var disposed = [Int](repeating: 0, count: roots.count)
        var originated = [Int](repeating: 0, count: roots.count)
        var witnesses = [Set<String>](repeating: [], count: roots.count)
        var safeMigrated = [Bool](repeating: false, count: roots.count)

        for rec in records {
            let p = PathScope.normalize(rec.fullPath)   // normalize ONCE
            // Witness parse at most once per record, shared across roots.
            var parsedWitnesses: [String]?
            for (i, root) in roots.enumerated() {
                // PathScope.contains semantics: "/" and "" never match.
                let underRoot = root.key != "/" && !root.key.isEmpty
                    && (p == root.key || p.hasPrefix(root.slashed))
                if underRoot {
                    total[i] += 1
                    if rec.isManuallyDeleted {
                        disposed[i] += 1
                        let parsed = parsedWitnesses
                            ?? parseWitnessesFromNote(rec.notes ?? "")
                        parsedWitnesses = parsed
                        for w in parsed { witnesses[i].insert(w) }
                    }
                }
                // Origination — legacy predicate verbatim.
                let originatedHere = (rec.originVolume == root.name)
                    || (rec.originalFullPath?.hasPrefix(root.originPrefix) ?? false)
                if originatedHere {
                    originated[i] += 1
                    // Safe-migrated-destination: originated here, currently
                    // living elsewhere, and its current host volume is safe.
                    // (Legacy hasSafeMigratedDestination used the raw-path
                    // prefix for "moved off"; preserve that.)
                    if !safeMigrated[i],
                       !rec.fullPath.hasPrefix(root.originPrefix),
                       isSafe(rec.fullPath) {
                        safeMigrated[i] = true
                    }
                }
            }
        }

        var out: [String: VolumeRetireStatus] = [:]
        out.reserveCapacity(roots.count)
        for (i, root) in roots.enumerated() {
            let usedAtSomePoint = total[i] > 0 || originated[i] > 0
            let allDisposed = usedAtSomePoint && disposed[i] == total[i]
            let hasSafeWitness = witnesses[i].contains(where: isSafe)
                || safeMigrated[i]
            out[root.key] = VolumeRetireStatus(
                totalRecords: total[i],
                disposedRecords: disposed[i],
                allDisposed: allDisposed,
                hasSafeWitness: hasSafeWitness
            )
        }
        return out
    }
}
