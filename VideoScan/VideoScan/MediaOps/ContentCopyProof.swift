// ContentCopyProof.swift
// "Does this other file hold the same bytes, NOW?" — the one proof Migrate's
// retire words and ⌘⌫'s surviving-copy gate stand on (Codex #150 F1/F3,
// rules 1, 2 and 6). Identity is whole-file SHA-256 (rule 6), never the
// partial MD5 or the sampled signature:
//   * both files carry a stored ContentFixity that is usable for
//     verification (sha256, ctime- and volume-bound stamp);
//   * the digests and byte counts are equal (a conflicting digest never
//     vouches);
//   * each stored stamp still describes the file at its path NOW — a live
//     stat under THE PERSISTENT DIGEST POLICY (`describesFileNow`: same
//     volume UUID, inode, size, mtime and ctime). That policy is the
//     project's one rule for when a stored digest may stand in for
//     re-reading the file.
// A file with no usable digest, a moved/rewritten/offline file, or a
// mismatch is "not proven" — the caller withholds the words or holds the
// file. Cost: one open+fstat per file checked (no reads); disk I/O, so call
// it off the main actor for anything but a handful of files.
// (An `enum` with no cases is Swift's namespace ≈ a C++ struct of statics.)

import CryptoKit
import Foundation
import VideoScanCore

enum ContentCopyProof {

    /// The record's stored whole-file SHA-256, when it can ever verify.
    nonisolated static func digest(_ r: VideoRecord) -> ContentFixity? {
        guard let f = r.contentFixity, f.isUsableForVerification, ArchiveDigestIndex.isSHA256(f.digest) else { return nil }
        return f
    }

    /// Same bytes by the stored whole-file SHA-256 (catalog only, no disk).
    nonisolated static func sameDigest(_ a: ContentFixity, _ b: ContentFixity) -> Bool {
        a.algorithm == ContentFixity.sha256 && b.algorithm == ContentFixity.sha256
            && a.digest == b.digest && a.byteCount == b.byteCount
    }

    /// The stored digest still describes the file at `path` now (live stat).
    nonisolated static func describesFileNow(_ f: ContentFixity, path: String) -> Bool {
        f.describesFileNow(FileIdentityStamp.capture(path: path))
    }

    /// Whole-file SHA-256 (lowercase hex) of the regular file at `path`,
    /// streamed in 1 MiB reads (memory: one 1 MiB buffer); nil when it is
    /// not a regular file, cannot be read, or is not `expectedBytes` long.
    nonisolated static func sha256(path: String, expectedBytes: Int64) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              Int64(info.st_size) == expectedBytes,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            // read(upToCount:) answers nil OR empty at end of file; a throw is a read error.
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        guard total == expectedBytes else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The Master Archive copy's read-back SHA-256 (`archiveFixity`), when
    /// it is one. It carries no stamp, so its live check is weaker (below).
    nonisolated static func archiveDigest(_ r: VideoRecord) -> ArchiveFixity? {
        guard let f = r.archiveFixity, f.algorithm == ContentFixity.sha256,
              ArchiveDigestIndex.isSHA256(f.digest) else { return nil }
        return f
    }

    /// One file and the digest on record for it — Sendable, so the live
    /// checks can run off the main actor. `fixity` is nil for a Master
    /// Archive copy known only by its read-back digest.
    struct Claim: Sendable, Equatable {
        let path: String
        let digest: String
        let byteCount: Int64
        let fixity: ContentFixity?

        init(path: String, fixity: ContentFixity) {
            self.path = path; self.digest = fixity.digest.lowercased()
            self.byteCount = fixity.byteCount; self.fixity = fixity
        }

        /// A file that must hash, fresh, to `digest` (no stamp to trust).
        init(path: String, digest: String, byteCount: Int64) {
            self.path = path; self.digest = digest.lowercased()
            self.byteCount = byteCount; self.fixity = nil
        }

        init(path: String, archive: ArchiveFixity) {
            self.path = path; self.digest = archive.digest.lowercased()
            self.byteCount = archive.sizeBytes; self.fixity = nil
        }

        /// The claim still holds for the file at `path` NOW. With a stamp:
        /// the persistent digest policy (racily-clean rule included). A
        /// Master Archive copy known only by its read-back digest has no
        /// stamp to trust, so it is HASHED IN FULL here, now (Codex closing
        /// pass F3, rule 2) — a same-size replacement fails. Off the main
        /// actor; cost = one full read of that copy.
        nonisolated func holdsNow() -> Bool {
            if let fixity { return ContentCopyProof.describesFileNow(fixity, path: path) }
            return ContentCopyProof.sha256(path: path, expectedBytes: byteCount) == digest
        }
    }

    /// `source` and at least one of `copies` hold the same bytes NOW: same
    /// SHA-256 and size on record (a conflicting digest never vouches), the
    /// source's stamp still describes it, and a copy still holds now.
    nonisolated static func proven(source: Claim, copies: [Claim]) -> Bool {
        let candidates = copies.filter {
            $0.digest == source.digest && $0.byteCount == source.byteCount && $0.path != source.path
        }
        guard !candidates.isEmpty, source.fixity != nil, source.holdsNow() else { return false }
        return candidates.contains { $0.holdsNow() }
    }
}

/// One Migrate source and its candidate copies, for the detached proof pass.
struct RelocateClaimSet: Sendable {
    let source: ContentCopyProof.Claim
    let copies: [ContentCopyProof.Claim]
}
