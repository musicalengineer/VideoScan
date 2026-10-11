// CatalogKnownCopies.swift
// "Is this the only copy we know of?" for the Catalog's Move to Trash
// (tab-charter audit T3, 2026-10-11 — the charter: ⌘⌫ is Finder-like, but
// warns when the file is the only copy).
//
// A copy is another catalog row with the SAME bytes by the catalog's
// strong identity keys — never the duplicate scan's scored, fuzzy match
// (a near-duplicate is not a copy; trusting one would hide the warning):
//   * partialMD5 + size        — the scan's identity key;
//   * contentHash + size       — the segmented content signature;
//   * a whole-file digest      — contentFixity / archiveFixity (fixity).
// It must SURVIVE the move: not one of the rows being trashed, not the
// same path catalogued twice, not removed or set aside. A copy on a drive
// that isn't connected still counts — it is a copy we know of.
//
// Cost: one pass over the catalog with three Set lookups per row; key
// strings are built only for the rows that already share a raw value with
// the selection. Pinned at 100k records by CatalogTrashOnlyCopyTests.
//
// (For Rick: an `enum` with no cases is Swift's namespace — like a C++
// struct holding only static functions.)

import Foundation
import VideoScanCore

enum CatalogKnownCopies {

    /// The identity keys of one row (empty values contribute none).
    nonisolated static func keys(_ r: VideoRecord) -> [String] {
        var out: [String] = []
        if !r.partialMD5.isEmpty { out.append("md5:\(r.partialMD5)|\(r.sizeBytes)") }
        if !r.contentHash.isEmpty { out.append("sig:\(r.contentHash)|\(r.sizeBytes)") }
        if let f = r.contentFixity, !f.digest.isEmpty { out.append("file:\(f.algorithm):\(f.digest)") }
        if let f = r.archiveFixity, !f.digest.isEmpty { out.append("file:\(f.algorithm):\(f.digest)") }
        return out
    }

    /// Of `moving`, the ids with no surviving copy in `all` by any key.
    /// A row with no identity key at all has no known copy.
    nonisolated static func onlyCopies(_ moving: [VideoRecord], in all: [VideoRecord]) -> Set<UUID> {
        guard !moving.isEmpty else { return [] }
        let leaving = Set(moving.map(\.id))
        let leavingPaths = Set(moving.map(\.fullPath))
        let md5s = Set(moving.map(\.partialMD5).filter { !$0.isEmpty })
        let sigs = Set(moving.map(\.contentHash).filter { !$0.isEmpty })
        let digests = Set(moving.flatMap { [$0.contentFixity?.digest, $0.archiveFixity?.digest] }
            .compactMap { $0 }.filter { !$0.isEmpty })
        var surviving = Set<String>()
        for r in all where !leaving.contains(r.id) {
            guard md5s.contains(r.partialMD5) || sigs.contains(r.contentHash)
                    || digests.contains(r.contentFixity?.digest ?? "")
                    || digests.contains(r.archiveFixity?.digest ?? "") else { continue }
            guard !r.isPurged, !r.isSetAside, !leavingPaths.contains(r.fullPath) else { continue }
            surviving.formUnion(keys(r))
        }
        return Set(moving.filter { rec in !keys(rec).contains(where: surviving.contains) }.map(\.id))
    }
}
