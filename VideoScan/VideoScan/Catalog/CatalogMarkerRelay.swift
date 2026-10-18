// CatalogMarkerRelay.swift
// How the ONE removal-marker writer (MediaOps/VideoScanModel+RemovalMarker
// .swift — `stampRemoval`, `revertRemoval`, `clearRemoval`, Trash emptied,
// RemovalUndo) reaches the SQLite committer (cutover B2.1 gap 2).
//
// catalog.sqlite records every marker change with its own tombstone, and
// the DDL refuses a change that skips a revision. Two changes inside one
// 2 s save window (Trash, then Undo) used to reach the commit as ONE jump
// and the row was refused. Now each change hands the committer a snapshot
// of the record AT THAT REVISION, taken where the change happened; the
// committer keeps it and lands every revision in order in its next commit
// (asked for at once — `scheduleCommit(after: .zero)`, so a batch of changes
// in one main-actor turn is still one commit).
//
// The writer is a `nonisolated static` function (some doors have no model
// at hand), so the relay is process-wide: committers register here (weakly)
// and each keeps only the snapshots of records it holds (same id AND same
// instance — CatalogCommitBaseline.takeJournal). Under catalog.json nothing
// is registered and the relay does nothing.
//
// A change made OFF the main thread is snapshotted on that thread (the
// value is Sendable) and delivered on the main queue.
//
// (For Rick: an observer list of weak pointers — the C++ `std::weak_ptr`
// subscriber pattern — with the payload copied at the call site.)

import Foundation
import VideoScanCore

enum CatalogMarkerRelay {

    @MainActor private static var committers: [WeakCommitter] = []

    private struct WeakCommitter {
        weak var committer: CatalogCommitter?
    }

    /// The committer of a session on catalog.sqlite.
    @MainActor static func register(_ committer: CatalogCommitter) {
        committers.removeAll { $0.committer == nil || $0.committer === committer }
        committers.append(WeakCommitter(committer: committer))
    }

    /// The marker of `record` just changed (its revision already bumped).
    nonisolated static func markerChanged(_ record: VideoRecord) {
        let id = record.id
        let instance = ObjectIdentifier(record)
        let snapshot = VideoRecordDTO(record)
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(id: id, instance: instance, snapshot: snapshot) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(id: id, instance: instance, snapshot: snapshot) }
            }
        }
    }

    @MainActor private static func deliver(id: UUID, instance: ObjectIdentifier, snapshot: VideoRecordDTO) {
        for entry in committers {
            entry.committer?.noteMarkerChange(id: id, instance: instance, snapshot: snapshot)
        }
    }
}
