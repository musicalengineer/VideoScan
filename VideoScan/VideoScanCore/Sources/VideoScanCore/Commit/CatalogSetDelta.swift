// CatalogSetDelta.swift
// The SHARED SETS a person edits — tags and backup attestations — written as
// each copy's own DELTA (cutover B2.4, codex B2.3 finding F2 "sets"), the
// way people already are (CatalogPeopleDelta, codex B2 P1-6).
//
// Why. The display tables are keyed by digest: every copy of one content
// shows one set. Before B2.4 each copy that changed the set DELETED the
// content's whole set and wrote its own, so two copies edited differently
// in one commit ended with whichever copy was written last: A {base}→
// {base,a} and B {base}→{base,b} stored {base,b} (or {base,a}), in memory
// and after a relaunch, with nothing said. Now each copy writes only what
// it added and what it removed since ITS OWN baseline (what it last agreed
// with the store on), so the store ends with {a, b, base} in either order;
// and A removing x while B adds y ends with neither x nor anything lost.
// A copy with no baseline (never seen stored) only adds — it never removes
// what it did not see.
//
// After the commit the store's resulting set is read back once per content
// (`SettledSets`, as a load gives it) and the app shows it on every copy —
// including the copies that wrote — so memory equals the next relaunch.
//
// (For Rick: set difference against a per-row snapshot — the two-way merge
// a version-control tool does per line, done per set element.)

import Foundation

/// What one copy added to and removed from a set since its own baseline.
/// Order of `now` is kept for the additions; duplicates collapse.
struct CatalogSetDelta<Element: Hashable> {
    private(set) var added: [Element] = []
    private(set) var removed: [Element] = []

    init(now: [Element], was: [Element]) {
        let before = Set(was)
        let after = Set(now)
        var seen = Set<Element>()
        added = now.filter { !before.contains($0) && seen.insert($0).inserted }
        removed = was.filter { !after.contains($0) && seen.insert($0).inserted }
    }
}

extension CatalogCommit {

    /// The shared sets of one content as the store ENDS a commit with them,
    /// read back the way a load gives them (cutover B2.4). The app puts them
    /// on every in-memory copy of the content.
    public struct SettledSets: Sendable, Equatable {
        public var tags: [String]
        public var backupAttestations: [BackupAttestation]
        public var confirmedByUserPeople: [ConfirmedTag]
        public var rejectedPeople: [String]

        init(_ loaded: VideoRecord) {
            tags = loaded.tags
            backupAttestations = loaded.backupAttestations
            confirmedByUserPeople = loaded.confirmedByUserPeople
            rejectedPeople = loaded.rejectedPeople
        }

        /// These sets in place of `shared`'s.
        public func apply(to shared: inout CatalogSharedCurated) {
            shared.tags = tags
            shared.backupAttestations = backupAttestations
            shared.confirmedByUserPeople = confirmedByUserPeople
            shared.rejectedPeople = rejectedPeople
        }
    }
}
