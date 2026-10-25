// CatalogMarkerRelay.swift
// How the ONE removal-marker writer (MediaOps/VideoScanModel+RemovalMarker
// .swift — `stampRemoval`, `revertRemoval`, `clearRemoval`, Trash emptied,
// RemovalUndo) reaches the SQLite committer (cutover B2.1 gap 2, re-scoped
// B2.2, veto B2.3).
//
// catalog.sqlite records every marker change with its own tombstone, and
// the DDL refuses a change that skips a revision. B2.2 makes that true by
// construction; B2.3 makes the answer BINDING (codex B2.2 P1):
//   * BEFORE a change (`markerWillChange`) — the committer answers nil (go)
//     or the words why not. A row whose previous marker change is not
//     committed yet is committed NOW, synchronously; when that cannot be
//     stored — or, for a person's request, when no commit can be written at
//     all (held, read-only, reopening) — the change is REFUSED and the
//     writer leaves the row exactly as it is (no revision bump);
//   * AFTER it (`markerChanged`) — the row is remembered and one commit is
//     asked for at once (zero delay), so a batch (Trash of 1,000 rows in
//     one main-actor turn) is still ONE commit.
// A door that is about to move a FILE asks first (`saveRefusal`, the same
// question) so a refusal comes before any disk work.
//
// The writer is a `nonisolated static` function (some doors have no model
// at hand), so the relay is process-wide: committers register here
// (weakly), and each answers only for ITS session's live records (a
// detached snapshot or another session's record is not its business).
// Under catalog.json nothing is registered and the relay always says go.
// Every marker door runs on the main actor today (checked 2026-10-18:
// VideoScanModel and CaptionOrchestrator are @MainActor; the audit fixer is
// @MainActor). A change made OFF the main thread cannot be pre-committed
// (the main thread cannot be waited on from there without a deadlock
// risk): it is not vetoed, its after-hook is delivered on the main queue,
// and a second change of the same row before that commit is refused by the
// store with the "changed N times within one save" words — named, never
// silent.
//
// (For Rick: an observer list of weak pointers — the C++ `std::weak_ptr`
// subscriber pattern — with a pre-mutation callback that can say no, and a
// post-mutation one.)

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

    /// The marker of `record` is about to change (its revision not yet
    /// bumped). nil = go; else "the catalog can't save (…); try again when
    /// …" and the change must NOT be made.
    nonisolated static func markerWillChange(_ record: VideoRecord, kind: CatalogMarkerChange = .request) -> String? {
        guard Thread.isMainThread else { return nil }
        // Swift 6: the relay is nonisolated BY DESIGN so the nonisolated doors
        // (`stampRemoval`, `revertRemoval`) can ask; the guard above proves we
        // are on the main thread, `record` is main-actor state every door
        // mutates there, and the closure is synchronous and non-escaping — so
        // handing the record to the main actor cannot race. The committer
        // needs the object itself (`owns` compares by identity).
        nonisolated(unsafe) let record = record
        return MainActor.assumeIsolated {
            for entry in committers {
                if let why = entry.committer?.markerWillChange(record, kind: kind) { return why }
            }
            return nil
        }
    }

    /// Asked by a door BEFORE it moves a file whose row it will then mark:
    /// would the marker change be refused? Same answer as `markerWillChange`.
    nonisolated static func saveRefusal(for record: VideoRecord) -> String? {
        markerWillChange(record, kind: .request)
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
