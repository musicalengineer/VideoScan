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
// The writer is a `static` function (some doors have no model at hand), so
// the relay is process-wide: committers register here (weakly), and each
// answers only for ITS session's live records (a detached snapshot or
// another session's record is not its business). Under catalog.json nothing
// is registered and the relay always says go.
// The relay and both doors (`stampRemoval`, `revertRemoval`) are `@MainActor`
// BY TYPE (Swift 6, 2026-10-25): every door into them is already main-actor
// isolated (VideoScanModel's instance methods, CatalogAuditFixer.apply,
// CaptionOrchestrator), so the compiler now carries the affinity that a
// `Thread.isMainThread` guard used to check at run time — and the old
// silent "off-main: not vetoed" branch no longer exists; an off-main caller
// is a compile error, not an unvetoed marker change.
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
    @MainActor static func markerWillChange(_ record: VideoRecord, kind: CatalogMarkerChange = .request) -> String? {
        for entry in committers {
            if let why = entry.committer?.markerWillChange(record, kind: kind) { return why }
        }
        return nil
    }

    /// Asked by a door BEFORE it moves a file whose row it will then mark:
    /// would the marker change be refused? Same answer as `markerWillChange`.
    @MainActor static func saveRefusal(for record: VideoRecord) -> String? {
        markerWillChange(record, kind: .request)
    }

    /// The marker of `record` just changed (its revision already bumped).
    @MainActor static func markerChanged(_ record: VideoRecord) {
        let id = record.id
        for entry in committers {
            entry.committer?.markerDidChange(id: id)
        }
    }
}
