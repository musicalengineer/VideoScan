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
//     case-insensitive by default), or the same inode on the same VOLUME
//     by the stamps' persistent volume UUIDs (`mayBeSameFile`).
//     These are STORED stamps, taken in different sessions: st_dev is
//     handed out per mount (ContentFixity.swift header), so a device number
//     is never consulted — after a remount it would make an alias of the
//     target look like a different file and hide the warning. When either
//     stamp has no volume UUID, a matching inode is taken as possibly the
//     same file: the error is an extra warning, never a missing one.
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

    /// The row's stored fixity stamp, when it names an inode.
    nonisolated static func fileStamp(_ r: VideoRecord) -> FileIdentityStamp? {
        guard let s = r.contentFixity?.stamp, s.inode != 0 else { return nil }
        return s
    }

    /// Could two STORED stamps name one file? Same inode, and not proven to
    /// be on different volumes: both volume UUIDs known and different is the
    /// only "different file" answer. A missing UUID cannot prove the volume,
    /// so it answers "maybe" — counted as the same file (no copy). st_dev is
    /// deliberately not read: it is not stable across remounts.
    nonisolated static func mayBeSameFile(_ a: FileIdentityStamp, _ b: FileIdentityStamp) -> Bool {
        guard a.inode == b.inode else { return false }
        guard let va = a.volumeUUID, let vb = b.volumeUUID else { return true }
        return va == vb
    }

    /// Of `moving`, the ids with no surviving copy in `all` by any key.
    /// `isSurvivor` is the caller's rule for a row that can still hold the
    /// bytes after the move. A row with no identity key has no known copy.
    nonisolated static func onlyCopies(_ moving: [VideoRecord], in all: [VideoRecord],
                                       isSurvivor: (VideoRecord) -> Bool) -> Set<UUID> {
        guard !moving.isEmpty else { return [] }
        let leaving = Set(moving.map(\.id))
        let leavingPaths = Set(moving.map { $0.fullPath.lowercased() })
        let leavingFiles = Dictionary(grouping: moving.compactMap(fileStamp), by: \.inode)
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
            if let file = fileStamp(r), leavingFiles[file.inode]?.contains(where: { mayBeSameFile($0, file) }) == true {
                continue
            }
            surviving.formUnion(keys(r))
        }
        return Set(moving.filter { rec in !keys(rec).contains(where: surviving.contains) }.map(\.id))
    }
}
