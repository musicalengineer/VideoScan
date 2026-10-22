// CatalogCutoverState.swift
// The model's one stored slot for the SQLite cutover (B2): the committer
// once catalog.sqlite is the authority, and the store's blocked words for the
// Reopen item. (The "Switch Catalog to SQLite…" sheet's request and progress
// left with that menu item, 2026-10-20.) One object so VideoScanModel gains
// ONE stored property.
//
// B2.1 adds:
//   * `awaitingDigest` — new rows held in `pending_rows` with no whole-file
//     hash yet (gap 1). They are handed to the scoped Fill In Full Hashes job
//     as soon as a job starter is attached (CatalogCutoverSheetHost attaches
//     one — it has the Media File Operations center); ids the job could not
//     take (one already running) stay here and are offered again on the
//     next request. The hash lands → the next save stores the row → it
//     leaves the set;
//   * `readOnlyReason` + `adoptRequest` — Catalog ▸ Adopt This SQLite
//     Catalog… (gap 5), offered only for a restored-below-high-water open.
//
// (For Rick: `ObservableObject` + `@Published` ≈ a class whose setters
// notify subscribed views — SwiftUI's observer pattern.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class CatalogCutoverState: ObservableObject {

    /// Non-nil once catalog.sqlite is the authority this session: every
    /// save funnel routes here instead of to the JSON store.
    private(set) var committer: CatalogCommitter?
    /// The database the committer writes.
    private(set) var databaseURL: URL?
    /// The store's words while commits are refused (read-only, reopen, a
    /// refusal); nil while writes go through.
    @Published private(set) var blockedReason: String?
    /// The words of a read-only OPEN (nil when the store opened writable,
    /// or once a person adopted or reopened it writable).
    @Published private(set) var readOnlyReason: String?

    /// The Adopt sheet (gap 5).
    @Published var adoptRequest: CatalogAdoptRequest?

    /// New rows waiting for a whole-file hash (gap 1).
    @Published private(set) var awaitingDigest: Set<UUID> = []
    /// Starts the scoped hash job for some ids. Attached by a view that has
    /// the Media File Operations center.
    private var digestJobStarter: ((Set<UUID>) -> Void)?

    var isSQLiteAuthority: Bool { committer != nil }

    /// Catalog ▸ Reopen SQLite Catalog is offered while saving has stopped —
    /// except after a file-stop (GH #359), where only quitting is safe.
    /// Re-read whenever `blockedReason` publishes.
    var canReopen: Bool { blockedReason != nil && committer?.canReopen == true }

    /// Only a restore below the high-water may be adopted.
    var canAdopt: Bool { readOnlyReason?.hasPrefix("restoredBelowHighWater") == true }

    func install(_ committer: CatalogCommitter, databaseURL: URL, readOnlyReason: String? = nil) {
        self.committer = committer
        self.databaseURL = databaseURL
        self.readOnlyReason = readOnlyReason
        blockedReason = committer.blockedReason
        committer.onBlockedChanged = { [weak self] reason in self?.blockedReason = reason }
        committer.onNeedDigest = { [weak self] ids in self?.requestDigests(ids) }
        committer.onHeldChanged = { [weak self] held in self?.awaitingDigest.formIntersection(held) }
        CatalogMarkerRelay.register(committer)
    }

    /// The store became writable (reopen / adopt).
    func noteWritable() {
        readOnlyReason = nil
    }

    /// Catalog ▸ Reopen SQLite Catalog.
    func reopen() async {
        guard let committer, let databaseURL else { return }
        await committer.reopen(at: databaseURL)
    }

    // MARK: - Fill In Full Hashes for held rows (gap 1)

    /// Attach the job starter (once the Media File Operations center is
    /// known); anything already waiting is offered at once.
    func attachDigestJobs(_ starter: @escaping (Set<UUID>) -> Void) {
        digestJobStarter = starter
        requestDigests([])
    }

    /// These held rows need their whole-file hash. Rows that have since
    /// become `files` rows (or left the catalog) drop out first.
    func requestDigests(_ ids: Set<UUID>) {
        awaitingDigest.formUnion(ids)
        if let held = committer?.heldIDs { awaitingDigest.formIntersection(held) }
        guard !awaitingDigest.isEmpty, let digestJobStarter else { return }
        digestJobStarter(awaitingDigest)
    }
}
