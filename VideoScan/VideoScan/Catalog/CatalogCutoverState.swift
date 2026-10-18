// CatalogCutoverState.swift
// The model's one stored slot for the SQLite cutover (B2): the committer
// once catalog.sqlite is the authority, the store's blocked words for the
// Reopen item, and the "Switch Catalog to SQLite…" sheet's request and
// progress. One object so VideoScanModel gains ONE stored property.
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

    /// The Switch sheet (`.sheet(item:)` in ContentView).
    @Published var switchRequest: CatalogSwitchRequest?
    /// Where the switch is (the sheet shows it).
    @Published var switchPhase: CatalogSwitchPhase = .confirming

    var isSQLiteAuthority: Bool { committer != nil }

    func install(_ committer: CatalogCommitter, databaseURL: URL) {
        self.committer = committer
        self.databaseURL = databaseURL
        blockedReason = committer.blockedReason
        committer.onBlockedChanged = { [weak self] reason in self?.blockedReason = reason }
    }

    /// Catalog ▸ Reopen SQLite Catalog.
    func reopen() async {
        guard let committer, let databaseURL else { return }
        await committer.reopen(at: databaseURL)
    }
}
