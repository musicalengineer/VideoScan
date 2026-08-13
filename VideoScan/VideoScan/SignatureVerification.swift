// SignatureVerification.swift
// The gate every destructive duplicate action must pass through.
//
// WHY THIS TYPE EXISTS. `segmentedHash` samples three 1 MiB windows out
// of files that reach 12 GB. It is excellent at saying "these are
// DIFFERENT" and incapable of saying "these are the SAME" — two files
// sharing a size and all three windows can still differ across the
// ~11.997 GB nobody read. I originally documented the segmented hash as
// "identity strong enough to delete on", which was false, and codex
// caught it before any delete feature shipped (#320).
//
// The fix is not more words in a comment. A rule that lives only in
// documentation gets forgotten by whoever writes the dedup UI in three
// weeks — possibly me. So the rule is a TYPE: to delete a duplicate you
// must hold a `VerifiedDuplicate`, and the only way to obtain one is to
// have compared every byte.
//
//     segmented hash equal   → CANDIDATE      (cheap, fleet-wide)
//     full hash equal        → VerifiedDuplicate (expensive, per pair)
//
// The asymmetry is deliberate: candidates are generated in minutes
// across a whole catalog, and verification is paid only on the handful
// of pairs a human is actually about to act on. That is the entire
// reason for having two hashes.

import Foundation

/// Proof that two paths hold byte-identical content.
///
/// Deliberately has no public initializer: the ONLY way to hold one is
/// `SignatureVerification.verify`, which reads both files in full. A
/// deletion API that takes this type cannot be called on unverified
/// candidates, which is the point — the compiler enforces what a comment
/// could only request.
struct VerifiedDuplicate: Equatable {
    let keeperPath: String
    let duplicatePath: String
    /// Full-file digest both sides produced.
    let fullHash: String
    let verifiedAt: Date

    fileprivate init(keeperPath: String, duplicatePath: String,
                     fullHash: String, verifiedAt: Date) {
        self.keeperPath = keeperPath
        self.duplicatePath = duplicatePath
        self.fullHash = fullHash
        self.verifiedAt = verifiedAt
    }
}

enum SignatureVerification {

    enum Failure: Error, Equatable {
        /// One or both files could not be read in full.
        case unreadable(String)
        /// They are genuinely different — the candidate was a false
        /// positive, which is exactly what verification is for.
        case contentDiffers
        /// Same path twice. Deleting "the duplicate" here would delete
        /// the only copy.
        case samePath
    }

    /// Compare two files byte-for-byte, via full-file digests.
    ///
    /// Expensive on purpose. Reads every byte of both files, so it is
    /// called on the pair about to be acted on, never across a catalog.
    ///
    /// Both sides are hashed FRESH at verification time rather than
    /// trusting anything stored: a signature computed last month says
    /// nothing about the bytes on disk right now, and the window between
    /// "decided to delete" and "deleted" is the one that matters.
    static func verify(keeperPath: String, duplicatePath: String)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }

        let keeperHash = FileHasher.fullHash(path: keeperPath)
        guard !keeperHash.isEmpty else { return .failure(.unreadable(keeperPath)) }

        let duplicateHash = FileHasher.fullHash(path: duplicatePath)
        guard !duplicateHash.isEmpty else { return .failure(.unreadable(duplicatePath)) }

        guard keeperHash == duplicateHash else { return .failure(.contentDiffers) }

        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: keeperHash,
            verifiedAt: Date()))
    }

    /// Human-facing description of what a matching signature does and
    /// does not establish. Used wherever the UI reports a duplicate, so
    /// the interface never repeats the overclaim the code made.
    static let candidateDisclaimer =
        "Matching signatures mean these files are very likely identical. "
        + "Every byte is compared before anything is deleted."
}
