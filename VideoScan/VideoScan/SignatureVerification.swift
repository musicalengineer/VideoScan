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
import Darwin
import CryptoKit

/// Filesystem identity and mutation stamp captured with one `stat` call.
/// Device + inode detects path replacement; size + nanosecond mtime detects
/// an in-place rewrite. The verification gate samples both before and after
/// hashing, then the deletion path samples once more immediately before
/// unlinking the duplicate. `stat` deliberately follows symlinks, matching
/// FileHasher's open/read behavior so the identity describes the bytes hashed.
fileprivate struct VerifiedFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func capture(path: String) -> VerifiedFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return VerifiedFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}

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
    let duplicateSize: Int64
    fileprivate let keeperIdentity: VerifiedFileIdentity
    fileprivate let duplicateIdentity: VerifiedFileIdentity

    fileprivate init(keeperPath: String, duplicatePath: String,
                     fullHash: String, verifiedAt: Date,
                     keeperIdentity: VerifiedFileIdentity,
                     duplicateIdentity: VerifiedFileIdentity) {
        self.keeperPath = keeperPath
        self.duplicatePath = duplicatePath
        self.fullHash = fullHash
        self.verifiedAt = verifiedAt
        self.duplicateSize = duplicateIdentity.size
        self.keeperIdentity = keeperIdentity
        self.duplicateIdentity = duplicateIdentity
    }
}

enum SignatureVerification {

    struct Hooks: @unchecked Sendable {
        var shouldCancel: () -> Bool
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

    /// Compare two files byte-for-byte, via full-file digests.
    ///
    /// Expensive on purpose. Reads every byte of both files, so it is
    /// called on the pair about to be acted on, never across a catalog.
    ///
    /// Both sides are hashed FRESH at verification time rather than
    /// trusting anything stored: a signature computed last month says
    /// nothing about the bytes on disk right now, and the window between
    /// "decided to delete" and "deleted" is the one that matters.
    static func verify(keeperPath: String, duplicatePath: String,
                       hooks: Hooks = .live)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }

        guard let keeperBefore = VerifiedFileIdentity.capture(path: keeperPath)
        else { return .failure(.unreadable(keeperPath)) }
        guard let duplicateBefore = VerifiedFileIdentity.capture(path: duplicatePath)
        else { return .failure(.unreadable(duplicatePath)) }

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

        guard let keeperAfter = VerifiedFileIdentity.capture(path: keeperPath),
              keeperAfter == keeperBefore else {
            return .failure(.changedSinceVerification(keeperPath))
        }
        guard let duplicateAfter = VerifiedFileIdentity.capture(path: duplicatePath),
              duplicateAfter == duplicateBefore else {
            return .failure(.changedSinceVerification(duplicatePath))
        }

        guard keeperHash == duplicateHash else { return .failure(.contentDiffers) }

        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: keeperHash,
            verifiedAt: Date(),
            keeperIdentity: keeperAfter,
            duplicateIdentity: duplicateAfter))
    }

    /// Revalidate the exact path identities captured by `verify`. This must
    /// be called immediately before a destructive action; a matching digest
    /// from moments ago is not authority to delete after either path changed.
    static func revalidate(_ proof: VerifiedDuplicate) -> Result<Void, Failure> {
        guard VerifiedFileIdentity.capture(path: proof.keeperPath)
                == proof.keeperIdentity else {
            return .failure(.changedSinceVerification(proof.keeperPath))
        }
        guard VerifiedFileIdentity.capture(path: proof.duplicatePath)
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

        let quarantineMatches = VerifiedFileIdentity.capture(path: quarantined.path)
            == proof.duplicateIdentity
        let keeperMatches = VerifiedFileIdentity.capture(path: proof.keeperPath)
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
        sha.update(data: Data("full:\(expectedSize):".utf8))
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
        return "full:" + sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Human-facing description of what a matching signature does and
    /// does not establish. Used wherever the UI reports a duplicate, so
    /// the interface never repeats the overclaim the code made.
    static let candidateDisclaimer =
        "Matching signatures mean these files are very likely identical. "
        + "Every byte is compared before anything is deleted."
}
