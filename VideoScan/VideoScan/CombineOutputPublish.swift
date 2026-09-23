// CombineOutputPublish.swift
//
// Putting a finished Combine output (<video>_combined.mov) at its name
// WITHOUT ever overwriting or deleting what is already there.
//
// The bug this exists for (audit, 2026-09-22): processCombinePair checked
// "does <video>_combined.mov exist?", then staged the inputs (minutes on a
// network volume), then ffmpeg wrote DIRECTLY to the final name with `-y`,
// and the failure and verify-failure paths called removeItem on the final
// name. Two pairs whose videos share a base name (different source folders,
// one output folder) — or anything else creating that name in the gap —
// could be overwritten or deleted.
//
// The rules:
//   1. ffmpeg writes a UNIQUELY named partial beside the destination (same
//      directory ⇒ same volume ⇒ the publish is a rename, not a copy). The
//      partial's name is RESERVED with O_CREAT|O_EXCL before ffmpeg runs, so
//      two concurrent pairs can never share one (PartialFileNaming).
//   2. Success + verify → publish with `renamex_np(RENAME_EXCL)`: an atomic
//      rename that FAILS if the name is taken. Never RENAME_SWAP /
//      `replaceItemAt` (the Sandbox.kext deadlock, AtomicFilePublish.swift).
//      Volumes that don't support RENAME_EXCL (exFAT, msdos, some SMB —
//      ENOTSUP/EINVAL) get the fallback in `renameNoClobber`.
//   3. Name taken → "name 2.mov", "name 3.mov", … (Finder style); the caller
//      logs it and catalogs the name actually published.
//   4. Failure / verify failure / cancel remove ONLY the partial this run
//      reserved — `removePartial` refuses any name that is not a partial.
//      A publish ERROR never removes a verified partial: it is kept and its
//      path reported.
//
// (For Rick: RENAME_EXCL ≈ link()+unlink() in one syscall — the kernel checks
// "destination absent" and renames atomically, so there is no check-then-act
// window like `fileExists` followed by `moveItem`.)
//
// UNIFY NOTE: fix/archive-protection-followups adds DerivativeOutputPublish
// (Transcode/Reformat) with the same partial naming, `besideURL`,
// `renameNoClobber` and an `Outcome` of the same shape. Once both are on
// main, `publish(partial:as:)` here is
//   DerivativeOutputPublish.publish(partial:, as:, policy: .keep(reason: …),
//                                   archiveCheck: nil, trash: { _ in nil })
// PLUS this file's ENOTSUP/EINVAL fallback, which that helper lacks.

import Darwin
import Foundation

enum CombineOutputPublish {

    enum Outcome: Sendable, Equatable {
        /// The name was free.
        case published(URL)
        /// The name was taken and kept; the new file landed at `url`.
        case publishedBeside(URL, keptExisting: URL, reason: String)

        var url: URL {
            switch self {
            case .published(let u), .publishedBeside(let u, _, _): return u
            }
        }
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// The RENAME_EXCL syscall. Returns 0 or an errno. Task-local test seam
    /// so the unsupported-volume fallback can be exercised without an exFAT
    /// disk; production = `renamex_np(…, RENAME_EXCL)`.
    @TaskLocal static var renameExclSyscall: @Sendable (String, String) -> Int32 = { src, dst in
        renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    // MARK: partials

    static func uniquePartialURL(for output: URL) -> URL {
        PartialFileNaming.uniquePartialURL(for: output)
    }

    static func isPartialName(_ name: String) -> Bool {
        PartialFileNaming.isPartialName(name)
    }

    /// Create an EMPTY partial with O_CREAT|O_EXCL so the name is ours alone
    /// before ffmpeg (`-y`) writes into it, and register it as live (so no
    /// stale-partial sweep — Combine's or Transcode's — touches it). The one
    /// shared reservation: PartialFileNaming.reserve.
    static func reservePartial(for output: URL) throws -> URL {
        do {
            return try PartialFileNaming.reserve(for: output)
        } catch let failure as PartialFileNaming.Failure {
            throw Failure(message: failure.message)
        }
    }

    /// Remove a partial this run reserved. Refuses (throws) for any name
    /// that is not a partial, so a caller bug can never delete a final.
    /// Already-gone is success. The removal itself (and the unregister) is
    /// PartialFileNaming.remove, which re-checks the name.
    static func removePartial(_ url: URL) throws {
        guard isPartialName(url.lastPathComponent) else {
            throw Failure(message: "refusing to remove \(url.lastPathComponent): not a Combine partial")
        }
        try PartialFileNaming.remove(url)
    }

    // MARK: publish

    /// Finder-style free-name candidate: "name 2.ext", "name 3.ext", …
    static func besideURL(for url: URL, attempt n: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// No-clobber rename. true = renamed; false = the destination exists
    /// (nothing changed); throws on any other failure (the source is then
    /// still at its own name).
    ///
    /// RENAME_EXCL unsupported (ENOTSUP/EINVAL — exFAT, msdos, some SMB):
    /// reserve the destination with O_CREAT|O_EXCL (an empty placeholder),
    /// confirm the name still holds OUR 0-byte file (same dev+ino), then
    /// rename(2) over it. The only thing rename can replace is that
    /// placeholder, which we created a moment earlier.
    static func renameNoClobber(_ source: String, _ destination: String) throws -> Bool {
        let e = renameExclSyscall(source, destination)
        if e == 0 { return true }
        if e == EEXIST { return false }
        guard e == ENOTSUP || e == EINVAL else {
            throw Failure(message: "rename to \((destination as NSString).lastPathComponent) failed: "
                          + String(cString: strerror(e)) + " (errno \(e))")
        }
        return try renameViaPlaceholder(source, destination, exclErrno: e)
    }

    private static func renameViaPlaceholder(_ source: String, _ destination: String,
                                             exclErrno: Int32) throws -> Bool {
        let name = (destination as NSString).lastPathComponent
        let fd = open(destination, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 {
            let oe = errno
            if oe == EEXIST { return false }
            throw Failure(message: "rename to \(name) failed: RENAME_EXCL unsupported (errno \(exclErrno)) "
                          + "and the name could not be reserved: " + String(cString: strerror(oe)) + " (errno \(oe))")
        }
        var mine = stat()
        let statOK = fstat(fd, &mine) == 0
        close(fd)
        guard statOK else {
            throw Failure(message: "rename to \(name) failed: could not stat the placeholder")
        }
        var now = stat()
        guard lstat(destination, &now) == 0,
              now.st_dev == mine.st_dev, now.st_ino == mine.st_ino, now.st_size == 0 else {
            // Someone replaced our placeholder: that file is theirs — treat
            // the name as taken and leave it alone.
            return false
        }
        if rename(source, destination) == 0 { return true }
        let re = errno
        // Take our placeholder back out — only if it is still ours and empty.
        var after = stat()
        if lstat(destination, &after) == 0,
           after.st_dev == mine.st_dev, after.st_ino == mine.st_ino, after.st_size == 0 {
            unlink(destination)
        }
        throw Failure(message: "rename to \(name) failed: " + String(cString: strerror(re)) + " (errno \(re))")
    }

    /// Publish `partial` as `final`, or beside it when the name is taken.
    /// Never touches an existing file. Throws only when nothing could be
    /// published — the partial is then still at its own name, and the
    /// caller must KEEP it (it is a verified output).
    static func publish(partial: String, as final: URL) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: partial) else {
            throw Failure(message: "the finished output is missing (\((partial as NSString).lastPathComponent))")
        }
        defer {
            if !FileManager.default.fileExists(atPath: partial) {
                PartialFileNaming.unregisterLive(URL(fileURLWithPath: partial))
            }
        }
        if try renameNoClobber(partial, final.path) { return .published(final) }
        let reason = "a file named \(final.lastPathComponent) is already there"
        for n in 2...200 {
            let candidate = besideURL(for: final, attempt: n)
            if try renameNoClobber(partial, candidate.path) {
                return .publishedBeside(candidate, keptExisting: final, reason: reason)
            }
        }
        throw Failure(message: "no free name beside \(final.lastPathComponent) after 199 tries")
    }

    /// A verified output that could not be published must survive: move
    /// it off the partial pattern (`<stem>.<token>.vs-kept.<ext>`) so the
    /// stale-partial sweep can never match it. If even that rename fails
    /// the partial stays where it is — the same directory-write failure
    /// that blocked the rename also blocks the sweep's unlink. Returns
    /// where the file now is.
    static func keepUnpublished(_ partial: URL) -> URL {
        defer { PartialFileNaming.unregisterLive(partial) }
        let name = partial.lastPathComponent
        guard isPartialName(name) else { return partial }
        let keptName = name.replacingOccurrences(of: ".\(PartialFileNaming.marker).", with: ".vs-kept.")
        let kept = partial.deletingLastPathComponent().appendingPathComponent(keptName)
        if (try? renameNoClobber(partial.path, kept.path)) == true { return kept }
        return partial
    }

    // MARK: stale-partial sweep

    typealias SweptPartial = PartialFileNaming.SweptPartial

    /// Remove partials in `folder` left by a crashed/killed run — through
    /// the ONE sweep Transcode uses too (PartialFileNaming.sweepStale):
    /// exact partial pattern, regular files, older than `olderThan`
    /// (default: the shared 24 h threshold), NEVER one a running job in this
    /// process reserved — Combine's or Transcode's. Each removal is logged
    /// with its size as swept by "combine". DISK I/O — call off-main.
    static func sweepStalePartials(in folder: URL, olderThan: TimeInterval = PartialFileNaming.staleThreshold,
                                   now: Date = Date()) -> (removed: [SweptPartial], errors: [String]) {
        PartialFileNaming.sweepStale(in: folder, job: "combine", olderThan: olderThan, now: now)
    }
}

/// Test seams for the Combine pipeline. Production never sets them.
enum CombineTestSeams {
    /// Called just before ffmpeg starts, with the destination name and the
    /// file ffmpeg will actually write. Lets a test put something at the
    /// destination in the window between the pre-check and the publish
    /// (the audit's 2026-09-22 race) or cancel the job mid-mux.
    @TaskLocal static var beforeMux: (@Sendable (_ destination: URL, _ writeTarget: URL) -> Void)? = nil
    /// Overrides "is this a network path?" for stageCombineInputs, so a
    /// test can force the buffering (staging-dir) path on a local file.
    @TaskLocal static var isNetworkPath: (@Sendable (String) -> Bool)? = nil
}
