import Foundation
import VideoScanCore

// MARK: - The removal marker's one writer (GH #143)
//
// Catalog half of the one Trash engine
// (docs/design/one_removal_marker_and_trash_engine.md §3). Every door that
// makes a row "gone" — the Trash engine's outcomes (`deleteConfirmedJunk`),
// Delete Duplicates' settle, Workbench discard, Remove from Catalog, the
// Archive Angel companion settle, the analysis missing-file purge, Migrate's
// Bucket B — stamps the row HERE, and Restore clears it here. Rows are never
// deleted when a file leaves.
//
// The disk half (gates, proof hook, the move itself, outcomes) is
// `deleteConfirmedJunk` in VideoScanModel+JunkDelete.swift.
//
// Legacy mirrors written here so the existing readers keep working:
//   - `purgedAt`        — derived from the marker (VideoRecord), nothing to do;
//   - `lifecycleStage`  — `.trashed` for inTrash (or the caller's explicit
//                         stage: the test seam's outright removal writes
//                         `.deletedPermanently`); other states leave it alone.
// `archiveStage .manuallyDeleted` is never written here. Restore clears it
// on a row whose marker came from that label, so a restored row is live.
//
// OneEngineSensorTests fails if a production file outside this one writes
// `.removal =`, `.purgedAt =`, or `lifecycleStage = .trashed / .deletedPermanently`.

extension VideoScanModel {

    /// Mark `rec` gone with `marker`. Idempotent for an identical marker.
    /// `stage` overrides the lifecycle mirror (nil = the marker's default).
    /// Does not save or publish: the door batches those (one save per batch).
    /// Static so a door with no model at hand (the caption orchestrator)
    /// still writes through the one function.
    nonisolated static func stampRemoval(_ rec: VideoRecord, _ marker: RemovalMarker, stage: LifecycleStage? = nil) {
        if rec.removal != marker { rec.removalRevision += 1 }
        rec.removal = marker
        if let mirror = stage ?? Self.lifecycleMirror(for: marker.state) {
            rec.lifecycleStage = mirror
        }
    }

    /// The lifecycle stage the legacy readers expect for a state; nil =
    /// leave the stage as it is.
    nonisolated static func lifecycleMirror(for state: RemovalMarker.State) -> LifecycleStage? {
        switch state {
        case .inTrash: return .trashed
        case .removedFromCatalog, .missing: return nil
        }
    }

    /// Undo one marker write BY VALUE AND REVISION, on whatever instance
    /// `rec` is now (codex 2026-10-16 F4, r2 F4; the audit's unsaved-batch
    /// rollback). Only when the row still carries exactly `wrote` AT the
    /// `revision` that write produced is its marker put back to `previous`
    /// (and the revision bumped again); each legacy mirror goes back only
    /// if it still holds the value the write itself left (so a newer
    /// lifecycle or archive-stage edit survives). No other field is
    /// touched. False = the row was changed by another door since — even
    /// back to an equal value (nil → Trash → Put Back → Restore → nil has a
    /// higher revision); there is nothing of ours to undo.
    /// (For Rick: a compare-and-swap on (marker, revision), then on each
    /// mirror — the revision is the ABA tag.)
    @discardableResult
    nonisolated static func revertRemoval(_ rec: VideoRecord, wrote: RemovalMarker?, previous: RemovalMarker?, revision: Int,
                                          mirrorsBefore: RemovalMirrors, mirrorsAfter: RemovalMirrors) -> Bool {
        guard rec.removal == wrote, rec.removalRevision == revision else { return false }
        rec.removal = previous
        rec.removalRevision += 1
        if rec.lifecycleStage == mirrorsAfter.lifecycleStage { rec.lifecycleStage = mirrorsBefore.lifecycleStage }
        if rec.archiveStage == mirrorsAfter.archiveStage { rec.archiveStage = mirrorsBefore.archiveStage }
        return true
    }

    /// Restore: the row is live again — but ONLY when that is true. nil
    /// means live, so a row whose file left the disk (In the Trash, Missing,
    /// or a legacy Trashed / Deleted stage) is restored only once the file is
    /// back at `fullPath` (codex round 1 F2: the marker used to be cleared
    /// first, so a file still in the Trash read as live and "Restore again"
    /// after Put Back found nothing to restore). Validate first; refuse with
    /// the marker untouched. Returns the line to log on a refusal, nil when
    /// the row went live. A row removed from the catalog (file untouched)
    /// always restores. On success a post-delete stage goes back to
    /// `.cataloged` (B4).
    func clearRemoval(_ rec: VideoRecord) -> String? {
        let fileLeft = rec.removal.map { $0.state != .removedFromCatalog } ?? false
            || rec.lifecycleStage == .trashed || rec.lifecycleStage == .deletedPermanently
        if fileLeft, rec.fullPath.isEmpty || !FileManager.default.fileExists(atPath: rec.fullPath) {
            return "\(rec.filename) is still in the Trash (or gone) — Put Back in Finder, then Restore again to mark it live."
        }
        if rec.removal != nil { rec.removalRevision += 1 }
        rec.removal = nil
        // A successful, explicit Restore clears the old "Manually Deleted"
        // label whichever legacy encoding won the migration (codex round 1
        // F4): left in place, the label re-hides the row on the next load.
        if rec.archiveStage == .manuallyDeleted { rec.archiveStage = .none }
        if rec.lifecycleStage == .trashed || rec.lifecycleStage == .deletedPermanently {
            rec.lifecycleStage = .cataloged
        }
        return nil
    }

    /// One row's "is its Trash copy still there?" question: the row's id and
    /// the Trash path macOS returned. Sendable, so the stats can run off the
    /// main actor.
    /// Also the probed marker's identity — its Trash path and when it moved
    /// (codex round 1 F5): a result is applied only to that same marker, never
    /// to a newer one the row got while the stats ran.
    struct TrashCopyProbe: Sendable, Equatable {
        let id: UUID
        let trashPath: String
        let movedAt: Date

        /// True when `marker` is still the one this probe asked about.
        func describes(_ marker: RemovalMarker) -> Bool {
            marker.state == .inTrash && marker.trashPath == trashPath && marker.since == movedAt
        }
    }

    /// The rows worth asking: In the Trash, a known Trash path, not yet seen
    /// emptied, and — an unplugged drive is not an emptied Trash — the Trash
    /// path's drive is reachable. One O(rows) pass on the main actor; the
    /// reachability answer is VolumeReachability's 5 s cache.
    func trashCopyProbes(in recs: [VideoRecord]) -> [TrashCopyProbe] {
        recs.compactMap { rec in
            guard let marker = rec.removal, marker.state == .inTrash, !marker.isTrashEmptied,
                  let trashPath = marker.trashPath else { return nil }
            if Self.isExternalVolumePath(trashPath), !VolumeReachability.isReachable(path: trashPath) { return nil }
            return TrashCopyProbe(id: rec.id, trashPath: trashPath, movedAt: marker.since)
        }
    }

    /// The probes whose Trash copy is gone. One stat each; pure apart from
    /// the stats, so it may run on any thread.
    nonisolated static func emptiedTrashCopies(_ probes: [TrashCopyProbe]) -> [TrashCopyProbe] {
        probes.filter { !FileManager.default.fileExists(atPath: $0.trashPath) }
    }

    /// Record "Trash emptied" on those rows (first sighting wins) — only
    /// where the row still carries the very marker that was probed. Returns
    /// how many changed; the caller saves.
    func applyTrashEmptied(_ gone: [TrashCopyProbe], now: Date) -> Int {
        var changed = 0
        for probe in gone {
            guard let rec = record(forID: probe.id), var marker = rec.removal,
                  probe.describes(marker), marker.noteTrashEmptied(at: now) else { continue }
            rec.removal = marker
            changed += 1
        }
        return changed
    }

    /// "Trash emptied", synchronously, for a known set of rows (tests and
    /// small batches). Returns how many changed; the caller saves.
    @discardableResult
    func noteEmptiedTrash(in recs: [VideoRecord], now: Date = Date()) -> Int {
        applyTrashEmptied(Self.emptiedTrashCopies(trashCopyProbes(in: recs)), now: now)
    }

    /// "Trash emptied" for the whole catalog, with the stats OFF the main
    /// actor (one per In-the-Trash row; nothing for any other row). Run when
    /// the person turns Show Removed on, so the words they read are fresh.
    /// Saves (debounced) and announces the in-place change when anything
    /// changed. Returns how many rows changed.
    @discardableResult
    func refreshTrashEmptied(now: Date = Date()) async -> Int {
        let probes = trashCopyProbes(in: records)
        guard !probes.isEmpty else { return 0 }
        let gone = await Task.detached(priority: .utility) { Self.emptiedTrashCopies(probes) }.value
        let changed = applyTrashEmptied(gone, now: now)
        if changed > 0 {
            saveCatalogDebounced()
            noteCatalogRecordsMutated()
        }
        return changed
    }

    /// The marker for one Trash-engine outcome (nil = the row is untouched:
    /// held, failed, offline, cancelled). Pure.
    nonisolated static func removalMarker(for outcome: JunkFileOutcome, outright: Bool,
                                          reason: RemovalReason, at now: Date) -> RemovalMarker? {
        switch outcome {
        case .held, .failed, .offline, .cancelled:
            return nil
        case .missing:
            return .missing(noticedAt: now, lastSeen: nil, reason: .missingAtTrashTurn)
        case .moved(_, let trashPath):
            // The test seam removes outright: there is no Trash copy, so the
            // honest state is "missing" (the legacy mirror says Deleted).
            return outright
                ? .missing(noticedAt: now, lastSeen: now, reason: reason)
                : .inTrash(movedAt: now, trashPath: trashPath, reason: reason)
        }
    }
}

/// The legacy mirrors a marker write may move — the lifecycle stage and
/// the archive label. A value, captured before and after a write, so
/// `revertRemoval` puts back only what the write itself moved.
struct RemovalMirrors: Sendable, Equatable {
    let lifecycleStage: LifecycleStage
    let archiveStage: ArchiveStage

    static func of(_ r: VideoRecord) -> RemovalMirrors {
        RemovalMirrors(lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage)
    }
}

/// A door that restored a row and then has to back out (Find Missing Audio's
/// pairing undo) puts the row back EXACTLY: the marker, the lifecycle mirror
/// and the archive label `clearRemoval` may have changed. Captured before
/// the restore. (For Rick: a tiny memento object ≈ a saved C++ struct copy.)
/// Holds the INSTANCE it was taken from: not for a rollback that may run
/// after a reload replaced the object — that is `revertRemoval`.
struct RemovalUndo {
    private let record: VideoRecord
    private let removal: RemovalMarker?
    private let lifecycleStage: LifecycleStage
    private let archiveStage: ArchiveStage

    init(_ record: VideoRecord) {
        self.record = record
        removal = record.removal
        lifecycleStage = record.lifecycleStage
        archiveStage = record.archiveStage
    }

    func reinstate() {
        record.removal = removal
        record.lifecycleStage = lifecycleStage
        record.archiveStage = archiveStage
    }
}

extension DeletionTier {
    /// How a duplicate that left by this tier is marked (GH #143). `.trash`
    /// → In the Trash, with the URL the Trash returned. `.permanent` is
    /// history only (Trash only since 2026-10-09): the file is gone with no
    /// Trash copy, so Missing, legacy stage Deleted. Pure.
    func removal(at now: Date, trashPath: String?) -> (marker: RemovalMarker, stage: LifecycleStage) {
        switch self {
        case .trash:
            return (.inTrash(movedAt: now, trashPath: trashPath, reason: .duplicate), .trashed)
        case .permanent:
            return (.missing(noticedAt: now, lastSeen: now, reason: .duplicate), .deletedPermanently)
        }
    }
}

extension RemovalReason {
    /// The verb the engine writes in its console lines for this door
    /// ("Discard: left 1 file(s) alone — …", "Cleanup: attempted=…"). Data,
    /// not a growing conditional: a door with its own voice adds one entry.
    /// Every other door speaks as Delete Confirmed Junk, as it always has.
    private static let doorVerbs: [RemovalReason: String] = [
        .workbench: "Discard",     // Triage ▸ Under Construction ▸ Discard
        .duplicate: "Cleanup",     // Triage ▸ Cleanup's copy lane (2026-10-12)
    ]

    var doorVerb: String { Self.doorVerbs[self] ?? "Delete Confirmed Junk" }
}
