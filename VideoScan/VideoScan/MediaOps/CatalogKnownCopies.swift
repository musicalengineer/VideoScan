// CatalogKnownCopies.swift
// "Is this the only copy we know of?" for the Catalog's Move to Trash
// (tab-charter audit T3, 2026-10-11 — the charter: ⌘⌫ is Finder-like, but
// warns when the file is the only copy).
//
// A copy is another catalog row with the SAME bytes by whole-file SHA-256
// (rule 6; Codex #150 F3) — never the partial MD5, the sampled signature or
// the duplicate scan's scored match:
//   * contentFixity — sha256, usable for verification (ctime- and
//     volume-bound stamp), or archiveFixity — the archive's read-back sha256;
//   * same digest AND byte count; a row whose two digests disagree has no
//     identity at all (a conflicting digest never vouches).
// A row without one has no known copy: the alert warns, and the move needs
// the person's deliberate click. At the move the copy is proven again on
// disk (`ContentCopyProof`).
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
// The model's survivor rule also drops a copy whose drive is not connected
// now (Codex #150 F3): it cannot be proven at the move.
//
// Cost: one pass over the catalog with two Set lookups per row; key
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
        let content = ContentCopyProof.digest(r).map { "sha256:\($0.digest.lowercased())|\($0.byteCount)" }
        let archive = ContentCopyProof.archiveDigest(r).map { "sha256:\($0.digest.lowercased())|\($0.sizeBytes)" }
        if let content, let archive, content != archive { return [] }   // conflicting digests: no identity
        return [content ?? archive].compactMap { $0 }
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
        let raw = RawValues(moving)
        var surviving = Set<String>()
        for r in all where !leaving.contains(r.id) {
            guard raw.shared(by: r) else { continue }
            guard isSurvivor(r), !leavingPaths.contains(r.fullPath.lowercased()) else { continue }
            if let file = fileStamp(r), leavingFiles[file.inode]?.contains(where: { mayBeSameFile($0, file) }) == true {
                continue
            }
            surviving.formUnion(keys(r))
        }
        return Set(moving.filter { rec in !keys(rec).contains(where: surviving.contains) }.map(\.id))
    }

    /// The rows of `all` that are a surviving copy of `rec` alone: same
    /// whole-file SHA-256 key, `isSurvivor`, not `rec` itself, not the same
    /// path (any case) and not maybe-the-same inode. The ⌘⌫ move's per-file
    /// question; `all` is the short candidate pool.
    nonisolated static func survivingCopies(of rec: VideoRecord, in all: [VideoRecord],
                                            isSurvivor: (VideoRecord) -> Bool) -> [VideoRecord] {
        let mine = Set(keys(rec))
        guard !mine.isEmpty else { return [] }
        let path = rec.fullPath.lowercased()
        let stamp = fileStamp(rec)
        let raw = RawValues([rec])
        return all.filter { r in
            guard r.id != rec.id, raw.shared(by: r), r.fullPath.lowercased() != path,
                  keys(r).contains(where: mine.contains), isSurvivor(r) else { return false }
            if let stamp, let other = fileStamp(r), mayBeSameFile(stamp, other) { return false }
            return true
        }
    }

    /// The rows of `all` that share a raw identity value with `moving` —
    /// the only rows that can be a copy of one (the same prefilter
    /// `onlyCopies` runs). One pass; the ⌘⌫ move asks `onlyCopies` per file
    /// against this short list instead of the whole catalog.
    nonisolated static func candidates(for moving: [VideoRecord], in all: [VideoRecord]) -> [VideoRecord] {
        guard !moving.isEmpty else { return [] }
        let raw = RawValues(moving)
        return all.filter(raw.shared(by:))
    }

    /// The raw whole-file digests of a set of rows (a cheap prefilter; the
    /// full key, size included, decides).
    private struct RawValues {
        let digests: Set<String>

        nonisolated init(_ moving: [VideoRecord]) {
            digests = Set(moving.flatMap { [$0.contentFixity?.digest, $0.archiveFixity?.digest] }
                .compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        }

        nonisolated func shared(by r: VideoRecord) -> Bool {
            guard !digests.isEmpty else { return false }
            // Both digests are stored lowercase (ContentFixity.init, ArchiveFixity).
            return digests.contains(r.contentFixity?.digest ?? "")
                || digests.contains(r.archiveFixity?.digest ?? "")
        }
    }
}
