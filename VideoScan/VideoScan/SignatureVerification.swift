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
// have compared every byte of the file about to be deleted against a
// whole-file digest of its keeper.
//
//     segmented hash equal   → CANDIDATE      (cheap, fleet-wide)
//     full hash equal        → VerifiedDuplicate (expensive, per pair)
//
// TWO WAYS TO EARN THE PROOF (Rick 2026-09-20 — "Delete 2,992 files"
// read BOTH files of every pair in full, hours with nothing to look at):
//
//   1. `verify(keeperPath:duplicatePath:)` — the original two-file path.
//      Both sides are read in full and hashed fresh.
//   2. `verifyAgainstStoredKeeper(...)` — the keeper is NOT read. Its
//      stored `ContentFixity` (whole-file digest + stat stamp from the
//      one time it was read) must reproduce under a fresh `stat`; then
//      only the DUPLICATE is read in full and its digest compared. If
//      the keeper has no fixity, or its stamp changed, this falls back to
//      path 1 ONCE and hands back the keeper's fresh fixity to be stored,
//      so the next pair with that keeper takes path 2.
//
// Either way the file that gets deleted is read end to end at the moment
// of deletion. Nothing stored — not `contentHash`, not `partialMD5`, not
// a fixity — ever authorises a delete on its own.

import Foundation
import Darwin
import CryptoKit
import VideoScanCore

/// Proof that two paths hold byte-identical content.
///
/// Deliberately has no public initializer: the ONLY ways to hold one are
/// `SignatureVerification.verify` and `verifyAgainstStoredKeeper`, both of
/// which read the duplicate in full. A deletion API that takes this type
/// cannot be called on unverified candidates, which is the point — the
/// compiler enforces what a comment could only request.
struct VerifiedDuplicate: Equatable, Sendable {
    let keeperPath: String
    let duplicatePath: String
    /// Whole-file SHA-256 (lowercase hex) both sides produced.
    let fullHash: String
    let verifiedAt: Date
    let duplicateSize: Int64
    /// The keeper's whole-file fixity: freshly computed when
    /// `keeperReadInFull`, otherwise the stored one that stood in for
    /// the read. Callers store it on the keeper record when it is fresh.
    let keeperFixity: ContentFixity
    /// The duplicate's fixity — moot once the file is gone, harmless to
    /// keep for the log.
    let duplicateFixity: ContentFixity
    /// True when this proof cost a full read of the keeper (path 1).
    let keeperReadInFull: Bool
    fileprivate let keeperIdentity: FileIdentityStamp
    fileprivate let duplicateIdentity: FileIdentityStamp

    fileprivate init(keeperPath: String, duplicatePath: String,
                     fullHash: String, verifiedAt: Date,
                     keeperIdentity: FileIdentityStamp,
                     duplicateIdentity: FileIdentityStamp,
                     keeperFixity: ContentFixity,
                     duplicateFixity: ContentFixity,
                     keeperReadInFull: Bool) {
        self.keeperPath = keeperPath
        self.duplicatePath = duplicatePath
        self.fullHash = fullHash
        self.verifiedAt = verifiedAt
        self.duplicateSize = duplicateIdentity.size
        self.keeperIdentity = keeperIdentity
        self.duplicateIdentity = duplicateIdentity
        self.keeperFixity = keeperFixity
        self.duplicateFixity = duplicateFixity
        self.keeperReadInFull = keeperReadInFull
    }
}

enum SignatureVerification {

    struct Hooks: @unchecked Sendable {
        var shouldCancel: () -> Bool
        /// Called once per block read, with "keeper" or "duplicate" — the
        /// seam tests use to count WHICH files were read.
        var didReadBlock: ((String) -> Void)?
        var didQuarantine: ((String) -> Void)?
        var removeQuarantineDirectory: ((URL) throws -> Void)?

        static let live = Hooks(shouldCancel: { Task.isCancelled })
    }

    enum Failure: Error, Equatable {
        /// One or both files could not be read in full.
        case unreadable(String)
        /// They are genuinely different — the candidate was a false
        /// positive, which is exactly what verification is for.
        case contentDiffers
        /// Same path twice. Deleting "the duplicate" here would delete
        /// the only copy.
        case samePath
        /// A path was replaced or rewritten while/after it was verified.
        /// The caller must start over rather than act on stale proof.
        case changedSinceVerification(String)
        case cancelled
    }

    // MARK: Path 1 — both files read in full

    /// Compare two files byte-for-byte, via full-file digests.
    ///
    /// Expensive on purpose. Reads every byte of both files, so it is
    /// called on the pair about to be acted on, never across a catalog.
    ///
    /// Both sides are hashed FRESH at verification time rather than
    /// trusting anything stored: a signature computed last month says
    /// nothing about the bytes on disk right now, and the window between
    /// "decided to delete" and "deleted" is the one that matters. (The
    /// stored-fixity path below is the ONE exception, and it is guarded by
    /// a fresh stat stamp of the keeper.)
    static func verify(keeperPath: String, duplicatePath: String,
                       hooks: Hooks = .live)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }

        guard let keeperBefore = FileIdentityStamp.capture(path: keeperPath)
        else { return .failure(.unreadable(keeperPath)) }
        guard let duplicateBefore = FileIdentityStamp.capture(path: duplicatePath)
        else { return .failure(.unreadable(duplicatePath)) }

        // Refusal accelerators (Rick 2026-08-17: a LaCie pass with ~1,400
        // name-alike NON-duplicates was paying two full 50 GB reads per
        // refusal — "at this rate it'll be tomorrow night"). Both gates
        // can only REFUSE faster; the delete path below still requires
        // full, fresh, identical hashes of both files.
        //   1. Different sizes can never be identical bytes.
        //   2. Same size but different first bytes: compare the heads
        //      before committing to two full reads (encodes/containers
        //      almost always diverge within the first few MB).
        guard keeperBefore.size == duplicateBefore.size else {
            return .failure(.contentDiffers)
        }
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        switch headsMatch(keeperPath: keeperPath, duplicatePath: duplicatePath) {
        case .some(false): return .failure(.contentDiffers)
        case .none: break            // unreadable head — let the full pass decide/report
        case .some(true): break
        }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let keeperHash = cancellableFullHash(
            path: keeperPath, label: "keeper", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !keeperHash.isEmpty else { return .failure(.unreadable(keeperPath)) }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let duplicateHash = cancellableFullHash(
            path: duplicatePath, label: "duplicate", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !duplicateHash.isEmpty else { return .failure(.unreadable(duplicatePath)) }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }

        guard let keeperAfter = FileIdentityStamp.capture(path: keeperPath),
              keeperAfter == keeperBefore else {
            return .failure(.changedSinceVerification(keeperPath))
        }
        guard let duplicateAfter = FileIdentityStamp.capture(path: duplicatePath),
              duplicateAfter == duplicateBefore else {
            return .failure(.changedSinceVerification(duplicatePath))
        }

        guard keeperHash == duplicateHash else { return .failure(.contentDiffers) }

        let now = Date()
        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: keeperHash,
            verifiedAt: now,
            keeperIdentity: keeperAfter,
            duplicateIdentity: duplicateAfter,
            keeperFixity: ContentFixity(digest: keeperHash, byteCount: keeperAfter.size,
                                        stamp: keeperAfter, computedAt: now),
            duplicateFixity: ContentFixity(digest: duplicateHash, byteCount: duplicateAfter.size,
                                           stamp: duplicateAfter, computedAt: now),
            keeperReadInFull: true))
    }

    // MARK: Path 2 — keeper by stored fixity, duplicate read in full

    /// Verify a duplicate against a keeper WITHOUT re-reading the keeper,
    /// when the keeper's stored whole-file fixity still describes the
    /// file on disk (fresh `stat` reproduces the stamp). The duplicate is
    /// read in full, its identity checked before and after the read, and
    /// its digest must equal the stored one with equal sizes.
    ///
    /// Falls back to `verify` (both files read) when there is no fixity,
    /// the fixity is not sha256, or the keeper's stamp changed — the
    /// returned proof then carries the keeper's FRESH fixity
    /// (`keeperReadInFull == true`) for the caller to store.
    static func verifyAgainstStoredKeeper(keeperPath: String,
                                          keeperFixity: ContentFixity?,
                                          duplicatePath: String,
                                          hooks: Hooks = .live)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }
        guard let keeperBefore = FileIdentityStamp.capture(path: keeperPath)
        else { return .failure(.unreadable(keeperPath)) }

        // No usable stored fixity → the two-file path, once.
        guard let fixity = keeperFixity,
              fixity.algorithm == ContentFixity.sha256,
              fixity.stampMatches(keeperBefore) else {
            return verify(keeperPath: keeperPath, duplicatePath: duplicatePath, hooks: hooks)
        }

        guard let duplicateBefore = FileIdentityStamp.capture(path: duplicatePath)
        else { return .failure(.unreadable(duplicatePath)) }
        // Different sizes can never be identical bytes — refuse before
        // reading anything.
        guard duplicateBefore.size == fixity.byteCount else {
            return .failure(.contentDiffers)
        }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let duplicateHash = cancellableFullHash(
            path: duplicatePath, label: "duplicate", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !duplicateHash.isEmpty else { return .failure(.unreadable(duplicatePath)) }

        // Identity re-check on BOTH sides after the read: the keeper must
        // still be the file the fixity describes, the duplicate the one
        // just hashed.
        guard let keeperAfter = FileIdentityStamp.capture(path: keeperPath),
              keeperAfter == keeperBefore else {
            return .failure(.changedSinceVerification(keeperPath))
        }
        guard let duplicateAfter = FileIdentityStamp.capture(path: duplicatePath),
              duplicateAfter == duplicateBefore else {
            return .failure(.changedSinceVerification(duplicatePath))
        }

        guard duplicateHash == fixity.digest else { return .failure(.contentDiffers) }

        let now = Date()
        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: duplicateHash,
            verifiedAt: now,
            keeperIdentity: keeperAfter,
            duplicateIdentity: duplicateAfter,
            keeperFixity: fixity,
            duplicateFixity: ContentFixity(digest: duplicateHash, byteCount: duplicateAfter.size,
                                           stamp: duplicateAfter, computedAt: now),
            keeperReadInFull: false))
    }

    /// Revalidate the exact path identities captured by `verify`. This must
    /// be called immediately before a destructive action; a matching digest
    /// from moments ago is not authority to delete after either path changed.
    static func revalidate(_ proof: VerifiedDuplicate) -> Result<Void, Failure> {
        guard FileIdentityStamp.capture(path: proof.keeperPath)
                == proof.keeperIdentity else {
            return .failure(.changedSinceVerification(proof.keeperPath))
        }
        guard FileIdentityStamp.capture(path: proof.duplicatePath)
                == proof.duplicateIdentity else {
            return .failure(.changedSinceVerification(proof.duplicatePath))
        }
        return .success(())
    }

    enum DeletionResult: Equatable {
        case deleted(bytes: Int64)
        case refused(Failure)
        case failed(String)
        case retainedQuarantine(path: String, reason: String)
    }

    /// Atomically moves the verified directory entry out of its public name
    /// before the final identity check. A replacement created at the original
    /// path can therefore never become the object subsequently removed.
    static func quarantineAndDelete(_ proof: VerifiedDuplicate,
                                    hooks: Hooks = .live) -> DeletionResult {
        guard !hooks.shouldCancel() else { return .refused(.cancelled) }
        if case .failure(let failure) = revalidate(proof) {
            return .refused(failure)
        }

        let original = URL(fileURLWithPath: proof.duplicatePath)
        let quarantineDirectory = original.deletingLastPathComponent()
            .appendingPathComponent(".videoscan-quarantine-\(UUID().uuidString)",
                                    isDirectory: true)
        let quarantined = quarantineDirectory.appendingPathComponent(original.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: original, to: quarantined)
        } catch {
            try? FileManager.default.removeItem(at: quarantineDirectory)
            return .failed("could not quarantine target: \(error.localizedDescription)")
        }

        hooks.didQuarantine?(quarantined.path)

        let quarantineMatches = FileIdentityStamp.capture(path: quarantined.path)
            == proof.duplicateIdentity
        let keeperMatches = FileIdentityStamp.capture(path: proof.keeperPath)
            == proof.keeperIdentity
        let originalOccupied = FileManager.default.fileExists(atPath: original.path)
        guard quarantineMatches, keeperMatches, !originalOccupied,
              !hooks.shouldCancel() else {
            let reason: String
            if hooks.shouldCancel() {
                reason = "cancelled after quarantine"
            } else if !quarantineMatches {
                reason = "quarantined file identity changed"
            } else if originalOccupied {
                reason = "original pathname was replaced during deletion"
            } else {
                reason = "keeper changed after verification"
            }
            return restoreOrRetain(
                quarantined: quarantined, original: original,
                quarantineDirectory: quarantineDirectory, reason: reason)
        }

        do {
            // No await or callback precedes this removal after the identity
            // check. The entry is isolated in a fresh owner-only directory.
            try FileManager.default.removeItem(at: quarantined)
        } catch {
            return .retainedQuarantine(
                path: quarantined.path,
                reason: "verified file retained because final removal failed: \(error.localizedDescription)")
        }

        // Empty-directory cleanup is housekeeping, not part of the media
        // deletion transaction. Once the quarantined file is gone, report
        // success so the catalog cannot retain a row for nonexistent media.
        do {
            if let removeDirectory = hooks.removeQuarantineDirectory {
                try removeDirectory(quarantineDirectory)
            } else {
                try FileManager.default.removeItem(at: quarantineDirectory)
            }
        } catch {
            NSLog("VideoScan: deleted verified duplicate but could not remove empty quarantine directory %@: %@",
                  quarantineDirectory.path, error.localizedDescription)
        }
        return .deleted(bytes: proof.duplicateSize)
    }

    private static func restoreOrRetain(quarantined: URL, original: URL,
                                        quarantineDirectory: URL,
                                        reason: String) -> DeletionResult {
        guard !FileManager.default.fileExists(atPath: original.path) else {
            return .retainedQuarantine(
                path: quarantined.path,
                reason: "\(reason); original pathname is occupied")
        }
        do {
            try FileManager.default.moveItem(at: quarantined, to: original)
            try FileManager.default.removeItem(at: quarantineDirectory)
            return .refused(.changedSinceVerification(original.path))
        } catch {
            return .retainedQuarantine(
                path: quarantined.path,
                reason: "\(reason); restore failed: \(error.localizedDescription)")
        }
    }

    /// Bytes compared by the head gate. 4 MB: past every container header
    /// and into the first frames, cheap on any medium.
    static let headCompareBytes = 4 * 1024 * 1024

    /// Compare the first `headCompareBytes` of both files. true = identical
    /// heads (files MAY still differ later — the full hash decides), false =
    /// definitely different, nil = could not read (caller falls through to
    /// the full pass so the real error is reported).
    static func headsMatch(keeperPath: String, duplicatePath: String,
                           bytes: Int = headCompareBytes) -> Bool? {
        func head(_ path: String) -> Data? {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var data = Data(count: bytes)
            let n = data.withUnsafeMutableBytes { buf -> Int in
                var total = 0
                while total < bytes {
                    let r = read(fd, buf.baseAddress! + total, bytes - total)
                    if r > 0 { total += r } else if r == 0 { break } else if errno != EINTR { return -1 }
                }
                return total
            }
            guard n >= 0 else { return nil }
            return data.prefix(n)
        }
        guard let a = head(keeperPath), let b = head(duplicatePath) else { return nil }
        return a == b
    }

    /// Whole-file SHA-256 as lowercase hex — the SAME value
    /// `CatalogStore.sha256HexStreaming` and the archive manifest carry, so
    /// a fixity written by Promote / Verify Archive is comparable here and
    /// vice versa. (Until 2026-09-20 this seeded the digest with
    /// "full:<size>:", which made it incomparable with every other sha256
    /// in the app; the size is compared separately by every caller.)
    /// Streams in `blockSize` blocks — bounded memory regardless of file
    /// size (worst case: one 1 MiB buffer). Returns "" on any I/O error,
    /// cancellation, or a size change mid-read.
    private static func cancellableFullHash(path: String, label: String,
                                            hooks: Hooks,
                                            blockSize: Int = FileHasher.segmentSize) -> String {
        guard blockSize > 0 else { return "" }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else { return "" }
        let expectedSize = Int(info.st_size)
        var sha = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            guard !hooks.shouldCancel() else { return "" }
            let count = read(fd, buffer, blockSize)
            if count > 0 {
                sha.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                total += count
                hooks.didReadBlock?(label)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return ""
            }
        }
        guard !hooks.shouldCancel(), total == expectedSize else { return "" }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Human-facing description of what a matching signature does and
    /// does not establish. Used wherever the UI reports a duplicate, so
    /// the interface never repeats the overclaim the code made.
    static let candidateDisclaimer =
        "Matching signatures mean these files are very likely identical. "
        + "Every byte is compared before anything is deleted."
}
