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

    /// One file and the digest on record for it — Sendable, so the live
    /// checks can run off the main actor.
    struct Claim: Sendable, Equatable {
        let path: String
        let fixity: ContentFixity
    }

    /// `source` and at least one of `copies` hold the same bytes NOW: same
    /// digest on record, and every stamp involved still describes its file.
    nonisolated static func proven(source: Claim, copies: [Claim]) -> Bool {
        let candidates = copies.filter { sameDigest(source.fixity, $0.fixity) && $0.path != source.path }
        guard !candidates.isEmpty, describesFileNow(source.fixity, path: source.path) else { return false }
        return candidates.contains { describesFileNow($0.fixity, path: $0.path) }
    }
}

/// One Migrate source and its candidate copies, for the detached proof pass.
struct RelocateClaimSet: Sendable {
    let source: ContentCopyProof.Claim
    let copies: [ContentCopyProof.Claim]
}
