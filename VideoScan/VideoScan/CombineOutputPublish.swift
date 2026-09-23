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
//   2. Success + verify → publish through ExclusivePublish (PartialFileNaming
//      .swift): `renamex_np(RENAME_EXCL)`, or on volumes without it (exFAT,
//      msdos, some SMB) `link(2)` — both fail atomically if the name is
//      taken. No hard links either → publish REFUSES; nothing is ever
//      renamed over (codex #1642, 2026-09-23: the old O_EXCL-placeholder +
//      lstat + rename(2) fallback overwrote a second writer in its window).
//      Never RENAME_SWAP / `replaceItemAt` (the Sandbox.kext deadlock,
//      AtomicFilePublish.swift).
//   3. Name taken → "name 2.mov", "name 3.mov", … (Finder style); the caller
//      logs it and catalogs the name actually published.
//   4. Failure / verify failure / cancel remove ONLY the partial this run
//      reserved — `removePartial` refuses any name that is not a partial.
//      A publish ERROR never removes a verified partial: it is kept
//      (protected, then moved to `.vs-kept.` if the drive allows) and its
//      path reported.
//
// (For Rick: RENAME_EXCL ≈ link()+unlink() in one syscall — the kernel checks
// "destination absent" and renames atomically, so there is no check-then-act
// window like `fileExists` followed by `moveItem`.)
//
// UNIFY NOTE: DerivativeOutputPublish (Transcode/Reformat) shares the
// partial naming, the keep, the sweep and — since codex #1642 — the
// no-clobber rename (ExclusivePublish). `publish(partial:as:)` here is
//   DerivativeOutputPublish.publish(partial:, as:, policy: .keep(reason: …),
//                                   archiveCheck: nil, trash: { _ in nil })
// in all but its Failure type.

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

    /// No-clobber rename (ExclusivePublish). true = renamed; false = the
    /// destination exists (nothing changed); throws on any other failure —
    /// including "the drive can't publish without risk of overwriting" —
    /// and the source is then still at its own name.
    static func renameNoClobber(_ source: String, _ destination: String) throws -> Bool {
        do {
            return try ExclusivePublish.renameNoClobber(source, destination)
        } catch let failure as PartialFileNaming.Failure {
            throw Failure(message: failure.message)
        }
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

    /// A verified output that could not be published must survive: it is
    /// protected on disk where it is (`<partial>.keep`, honoured by every
    /// sweep, across restarts), then moved off the partial pattern to the
    /// first free `<stem>.<token>[-n].vs-kept.<ext>` — never overwriting.
    /// On a drive that can't rename exclusively it stays at its partial
    /// name, protected. Returns where the file now is.
    static func keepUnpublished(_ partial: URL) -> URL {
        PartialFileNaming.keepUnpublished(partial, renameNoClobber: renameNoClobber)
    }

    // MARK: stale-partial sweep

    typealias SweptPartial = PartialFileNaming.SweptPartial

    /// Remove partials in `folder` left by a crashed/killed run — through
    /// the ONE sweep Transcode uses too (PartialFileNaming.sweepStale):
    /// exact partial pattern, regular files, older than `olderThan`
    /// (default: the shared 24 h threshold), NEVER one a running job in this
    /// process reserved — Combine's or Transcode's — and NEVER a protected
    /// finished output. Each removal is logged with its size as swept by
    /// "combine". DISK I/O — call off-main.
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
