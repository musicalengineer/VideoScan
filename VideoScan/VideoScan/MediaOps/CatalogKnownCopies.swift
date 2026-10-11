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
// It must SURVIVE the move (QA round 1, M2):
//   * the caller's survivor rule — the model passes the Migrate witness
//     rule (`isLiveRelocateWitness`: not removed, not trashed, not labelled
//     deleted, not a skipped row) plus not superseded, not set aside, not
//     on a retired drive;
//   * not one of the rows being trashed;
//   * not the SAME FILE: the same path ignoring case (macOS volumes are
//     case-insensitive by default), or — when both rows' fixity stamps
//     carry a device + inode — the same device + inode.
// A copy on a drive that is merely disconnected still counts.
//
// Cost: one pass over the catalog with three Set lookups per row; key
// strings are built only for rows that already share a raw value with the
// selection. Pinned at 100k records by CatalogTrashOnlyCopyTests.
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

    /// "device:inode" from the row's fixity stamp, when it carries one.
    nonisolated static func fileIdentity(_ r: VideoRecord) -> String? {
        guard let s = r.contentFixity?.stamp, s.device != 0 || s.inode != 0 else { return nil }
        return "\(s.device):\(s.inode)"
    }

    /// Of `moving`, the ids with no surviving copy in `all` by any key.
    /// `isSurvivor` is the caller's rule for a row that can still hold the
    /// bytes after the move. A row with no identity key has no known copy.
    nonisolated static func onlyCopies(_ moving: [VideoRecord], in all: [VideoRecord],
                                       isSurvivor: (VideoRecord) -> Bool) -> Set<UUID> {
        guard !moving.isEmpty else { return [] }
        let leaving = Set(moving.map(\.id))
        let leavingPaths = Set(moving.map { $0.fullPath.lowercased() })
        let leavingFiles = Set(moving.compactMap(fileIdentity))
        let md5s = Set(moving.map(\.partialMD5).filter { !$0.isEmpty })
        let sigs = Set(moving.map(\.contentHash).filter { !$0.isEmpty })
        let digests = Set(moving.flatMap { [$0.contentFixity?.digest, $0.archiveFixity?.digest] }
            .compactMap { $0 }.filter { !$0.isEmpty })
        var surviving = Set<String>()
        for r in all where !leaving.contains(r.id) {
            guard md5s.contains(r.partialMD5) || sigs.contains(r.contentHash)
                    || digests.contains(r.contentFixity?.digest ?? "")
                    || digests.contains(r.archiveFixity?.digest ?? "") else { continue }
            guard isSurvivor(r), !leavingPaths.contains(r.fullPath.lowercased()) else { continue }
            if let file = fileIdentity(r), leavingFiles.contains(file) { continue }
            surviving.formUnion(keys(r))
        }
        return Set(moving.filter { rec in !keys(rec).contains(where: surviving.contains) }.map(\.id))
    }
}
