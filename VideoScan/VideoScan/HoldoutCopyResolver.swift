// HoldoutCopyResolver.swift
// Offline-copy preview resolution for the blind holdout review
// (feature/holdout-offline-copy-preview, Rick 2026-07-30).
//
// Rick's 5 pending holdout rows live on the unmounted
// /Volumes/RicksBackups/; each has a verified byte-identical copy on the
// mounted /Volumes/LaCieWorkspace/. The offline sweep used to just hide
// those rows behind a "reconnect the drive" message. This resolver lets
// the sheet PREVIEW them via the live copy instead — thumbnail, Open in
// QuickTime, Reveal, reachability all point at the copy — while the row's
// sealed identity (fullPath / reviewId) and the yes/no write-back stay
// UNCHANGED. The copy is preview-only.
//
// Blindness is preserved by construction: the match is BYTE-IDENTICAL
// content (partialMD5+size, or Avid UMID+streamType, or duplicateGroupID
// — exactly OnlineCopyFinder.sameContentCopies), so nothing about the
// model's opinion leaks. Match strictness is strong-identity ONLY — Rick
// ruled out any name+size fallback (a wrong copy would defeat the point).
//
// Pure logic, Foundation-only — no Process, no disk, no VolumeReachability.
// The caller injects `isLive`, mirroring OnlineCopyFinder's `isOnline`
// style, which keeps every path here unit-testable and keeps the O(n)
// index build off the SwiftUI view body (the 100k-row scale test forbids
// O(records) work in a body — build once, store the result).

import Foundation

struct HoldoutCopyResolver {

    private let finder: OnlineCopyFinder
    private let byPath: [String: VideoRecord]

    /// Build once from the catalog. O(records): the OnlineCopyFinder
    /// content indexes plus a fullPath → record lookup. Do this off the
    /// view body and keep the instance (or just its resolved output) in
    /// @State.
    init(records: [VideoRecord]) {
        self.finder = OnlineCopyFinder(records: records)
        // Last-writer-wins on duplicate paths — the catalog is single-path
        // keyed in practice; this is only a defensive collapse.
        self.byPath = Dictionary(records.map { ($0.fullPath, $0) },
                                 uniquingKeysWith: { _, last in last })
    }

    /// Resolve an offline original path to a currently-live byte-identical
    /// copy, or nil if there is no strong-identity match that is live.
    ///
    /// - `isLive` decides whether a candidate copy path is usable right now
    ///   (mounted volume + file present). Injected so this stays pure.
    ///
    /// Returns the first copy — in sameContentCopies' deterministic order
    /// (hash-key tier first, then UMID, then dup-group; stable by path
    /// within each tier) — whose path `isLive`. A record we can't find in
    /// the catalog can't be strong-matched, so it returns nil (the sweep
    /// then keeps the original hidden, unchanged behavior).
    func liveCopy(for originalPath: String, isLive: (String) -> Bool) -> String? {
        guard let record = byPath[originalPath] else { return nil }
        for copy in finder.sameContentCopies(of: record) where isLive(copy.fullPath) {
            return copy.fullPath
        }
        return nil
    }

    /// The ordered strong-identity copy candidates for an offline original,
    /// WITHOUT any liveness check — the caller does the (blocking) mounted-
    /// volume + fileExists test itself, in whatever off-main context it
    /// already owns. Empty when the path isn't in the catalog. Precomputing
    /// these on the main actor (where `records` lives) lets the ConfirmSheet
    /// hand a plain [String] map into its existing @concurrent sweep.
    func copyCandidates(for originalPath: String) -> [String] {
        guard let record = byPath[originalPath] else { return [] }
        return finder.sameContentCopies(of: record).map(\.fullPath)
    }
}
