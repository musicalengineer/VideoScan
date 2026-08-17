import Darwin
import Foundation

// MARK: - RelocateEngine
//
// Pure, nonisolated copy+verify engine for the Relocate Volume feature.
// Takes a Sendable RelocateJob, performs the actual file copy via
// FileManager.copyItem (which routes to copyfile(3) with COPYFILE_ALL —
// preserves xattrs, ACLs, and FinderInfo across HFS+ → APFS), verifies
// the destination by size + partial-MD5, and returns a RelocateOutcome.
//
// No VideoScanModel reference. No catalog mutation. No UI. The model
// layer is responsible for translating outcomes into catalog updates.
// See docs/relocate_volume_plan.md §3.

struct RelocateJob: Sendable, Equatable {
    let recordID: UUID
    let sourcePath: String
    let destPath: String
    let expectedBytes: Int64
    /// May be empty for legacy records — engine will size-verify only
    /// and log a warning instead of failing on hash mismatch.
    let expectedPartialMD5: String
}

enum RelocateOutcome: Equatable {
    case success(actualBytes: Int64, newPartialMD5: String, copyDuration: TimeInterval)
    case salvageFailed(reason: String, stage: Stage)

    enum Stage: String, Equatable {
        case preRead        // 1-byte probe before opening the door to a big copy
        case copy           // copyItem itself threw, or destination already exists
        case postStat       // couldn't read attributes of dest after copy
        case sizeMismatch   // dest size != expectedBytes
        case hashMismatch   // dest partial-MD5 != expectedPartialMD5
    }
}

enum RelocateEngine {

    /// Copy a single record's source file to its destination, verify, and
    /// return the outcome. Never throws — failures surface as
    /// `.salvageFailed(...)` so the caller can keep iterating through a
    /// batch without partial-batch state.
    ///
    /// The destination's parent directory is created if needed. A
    /// pre-existing file at the destination is treated as a failure
    /// (likely a half-finished previous run); the reconcile phase's
    /// "adopt already-at-dest" bucket handles the legitimate case.
    // @concurrent: this project builds with NonisolatedNonsendingByDefault,
    // under which a nonisolated async function runs on the CALLER's actor.
    // The caller (VideoScanModel.runRelocate) is @MainActor, so without this
    // every copy + verify ran ON THE MAIN THREAD — Rick 2026-08-17: "0/2111
    // … the UI seems beachbally" while 361 GB flowed. Fourth incident of
    // the approachable-concurrency trap; see the memo. The #if guard
    // matches the pattern used elsewhere (CI Xcode 16.4 has no
    // @concurrent; there the old semantics already ran it off-actor).
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func runOne(_ job: RelocateJob,
                       fileManager: FileManager = .default) async -> RelocateOutcome {
        // Stage 1: destination collision check.
        if fileManager.fileExists(atPath: job.destPath) {
            return .salvageFailed(
                reason: "destination already exists: \(job.destPath)",
                stage: .copy
            )
        }

        // Stage 2: pre-read probe. Open the source O_RDONLY, read 1 byte.
        // On a dying HDD this surfaces I/O failure in ~1s instead of after
        // an N-GB stalled copy. Empty (0-byte) source files are tolerated:
        // open succeeds, read returns 0 with no error.
        if let probeError = probeSource(job.sourcePath) {
            return .salvageFailed(reason: probeError, stage: .preRead)
        }

        // Stage 3: create intermediate directories under the destination.
        let destURL = URL(fileURLWithPath: job.destPath)
        let destDir = destURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: destDir,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        } catch {
            return .salvageFailed(
                reason: "cannot create destination directory: \(error.localizedDescription)",
                stage: .copy
            )
        }

        // Stage 4: copy. copyfile(3) under the hood — preserves xattrs,
        // ACLs, FinderInfo. HFS+ → APFS attribute migration handled by
        // the OS.
        let started = Date()
        do {
            try fileManager.copyItem(atPath: job.sourcePath, toPath: job.destPath)
        } catch {
            // Best-effort cleanup of half-written dest so we don't leave
            // truncated files lying around. Ignore removal failures —
            // the original copy error is the interesting one.
            try? fileManager.removeItem(atPath: job.destPath)
            return .salvageFailed(
                reason: "copy failed: \(error.localizedDescription)",
                stage: .copy
            )
        }
        let copyDuration = Date().timeIntervalSince(started)

        // Stage 5: post-copy stat for size.
        let actualBytes: Int64
        do {
            let attrs = try fileManager.attributesOfItem(atPath: job.destPath)
            actualBytes = (attrs[.size] as? Int64) ?? -1
        } catch {
            return .salvageFailed(
                reason: "cannot stat destination: \(error.localizedDescription)",
                stage: .postStat
            )
        }
        if actualBytes != job.expectedBytes {
            // Leave the dest in place — Rick may want to inspect it.
            return .salvageFailed(
                reason: "size mismatch: expected \(job.expectedBytes), got \(actualBytes)",
                stage: .sizeMismatch
            )
        }

        // Stage 6: partial-MD5 verify. Skipped (size-only) when the
        // catalog never stored a hash for this record.
        let newHash = FileHasher.partialMD5(path: job.destPath)
        if !job.expectedPartialMD5.isEmpty {
            if newHash.isEmpty {
                return .salvageFailed(
                    reason: "could not compute hash of destination",
                    stage: .hashMismatch
                )
            }
            if newHash != job.expectedPartialMD5 {
                return .salvageFailed(
                    reason: "hash mismatch: expected \(job.expectedPartialMD5) got \(newHash)",
                    stage: .hashMismatch
                )
            }
        }

        return .success(actualBytes: actualBytes,
                        newPartialMD5: newHash,
                        copyDuration: copyDuration)
    }

    // MARK: - Internals

    /// Open the source file, read 1 byte. Closes on the way out either way.
    /// Returns nil on success (zero-byte files allowed); error message
    /// otherwise. Catches drive-level read failures fast.
    private static func probeSource(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return "cannot open source: \(String(cString: strerror(errno)))"
        }
        defer { close(fd) }

        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        if n < 0 {
            return "cannot read source: \(String(cString: strerror(errno)))"
        }
        return nil
    }
}
