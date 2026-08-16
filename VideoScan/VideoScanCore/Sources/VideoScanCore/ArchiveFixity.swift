// ArchiveFixity.swift
// Full-file fixity for Master Archive copies (docs/archive_promotion_
// workflow.md §5, codex QA blocker 3, 2026-08-15).
//
// `VideoRecord.contentHash` is the v1 SEGMENTED candidate signature
// (`v1:<sha256>` over head‖middle‖tail‖size) — the catalog-wide identity
// key used for duplicate detection and delete authorization. A full-file
// digest must never be written there: it would never match anything and
// would silently break the segmented contract. So the archive's
// whole-file SHA-256 gets its own additive, optional field.
//
// (For Rick: a small POD struct — algorithm tag + hex digest + when it
// was verified + the byte count it covered.)

import Foundation

public struct ArchiveFixity: Codable, Equatable, Hashable, Sendable {
    /// Digest algorithm tag — "sha256" today; the tag exists so a future
    /// algorithm change never has to reinterpret old digests.
    public let algorithm: String
    /// Lowercase hex digest of the ENTIRE file as it landed in the archive
    /// (computed by an independent read-back after the copy).
    public let digest: String
    /// When the read-back verification produced `digest`.
    public let verifiedAt: Date
    /// File size the digest covers — a cheap first-line tamper/truncation
    /// check before re-hashing.
    public let sizeBytes: Int64

    public init(algorithm: String = "sha256", digest: String, verifiedAt: Date, sizeBytes: Int64) {
        self.algorithm = algorithm
        self.digest = digest
        self.verifiedAt = verifiedAt
        self.sizeBytes = sizeBytes
    }
}
