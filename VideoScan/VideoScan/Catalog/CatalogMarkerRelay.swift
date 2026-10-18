// CatalogMarkerRelay.swift
// How the ONE removal-marker writer (MediaOps/VideoScanModel+RemovalMarker
// .swift — `stampRemoval`, `revertRemoval`, `clearRemoval`, Trash emptied,
// RemovalUndo) reaches the SQLite committer (cutover B2.1 gap 2, re-scoped
// B2.2).
//
// catalog.sqlite records every marker change with its own tombstone, and
// the DDL refuses a change that skips a revision. B2.2 makes that true by
// construction instead of by replay:
//   * BEFORE a change (`markerWillChange`) — rows whose previous marker
//     change is not committed yet are committed NOW, synchronously, so the
//     store holds revision n before the record moves to n+1;
//   * AFTER it (`markerChanged`) — the row is remembered and one commit is
//     asked for at once (zero delay), so a batch (Trash of 1,000 rows in
//     one main-actor turn) is still ONE commit.
// (B2.1 kept a snapshot per revision and replayed them later; codex's
// closing pass showed the replay could lose a curated reversion and drop
// revisions during a first insert. The replay queue is gone.)
//
// The writer is a `nonisolated static` function (some doors have no model
// at hand), so the relay is process-wide: committers register here
// (weakly). Under catalog.json nothing is registered and the relay does
// nothing. Every marker door runs on the main actor today (checked
// 2026-10-18: VideoScanModel and CaptionOrchestrator are @MainActor; the
// audit fixer is @MainActor). A change made OFF the main thread cannot be
// pre-committed (the main thread cannot be waited on from there without a
// deadlock risk): its after-hook is delivered on the main queue, and a
// second change of the same row before that commit is refused by the store
// with the "changed N times within one save" words — named, never silent.
//
// (For Rick: an observer list of weak pointers — the C++ `std::weak_ptr`
// subscriber pattern — with a pre- and a post-mutation callback.)

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

    /// The marker of `record` may be about to change (its revision not yet
    /// bumped). On the main thread: an uncommitted earlier change is
    /// committed first.
    nonisolated static func markerWillChange(_ record: VideoRecord) {
        guard Thread.isMainThread else { return }
        let id = record.id
        MainActor.assumeIsolated {
            for entry in committers { entry.committer?.markerWillChange(id: id) }
        }
    }

    /// The marker of `record` just changed (its revision already bumped).
    nonisolated static func markerChanged(_ record: VideoRecord) {
        let id = record.id
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(id) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(id) }
            }
        }
    }

    @MainActor private static func deliver(_ id: UUID) {
        for entry in committers {
            entry.committer?.markerDidChange(id: id)
        }
    }
}
