// DerivativeOutputPublish.swift
//
// Putting a finished derivative (a Transcode output) at its name WITHOUT
// ever deleting what is already there first.
//
// The bug this exists for (QA, 2026-09-22 — older than the archive-volume
// protection): TranscodeJob removed the file at its output name BEFORE the
// source-missing check and before any encode existed. Output names are
// fixed (`<stem>.vs.<purpose>.<ext>`) and the sheet defaults an archived
// source's destination to the archive's OWN year folder, so answering
// "Replace Existing Transcode?" permanently deleted a catalogued file on
// FamilyArchive — even when the encode then failed.
//
// The rules, in order:
//   1. ffmpeg writes a UNIQUELY named partial beside the destination.
//      Nothing at the destination is touched while it runs.
//   2. The partial is published with `renamex_np(RENAME_EXCL)` — an
//      atomic rename that FAILS if the name is taken. Never RENAME_SWAP /
//      `replaceItemAt` (the Sandbox.kext deadlock, AtomicFilePublish.swift).
//   3. Name taken, Replace NOT chosen → published beside it ("name 2.ext").
//   4. Name taken, Replace chosen → the existing file may go ONLY to the
//      Trash (never `removeItem`), ONLY after the new output is present,
//      and ONLY when the Master Archive rule allows it (`bulkDeleteRefusal`
//      decides the policy on the main actor; the file's OWN volume UUID is
//      re-read here, off-main). Otherwise it is kept and the new file is
//      published beside it — and the job says so.
//
// (For Rick: RENAME_EXCL ≈ `link()+unlink()` semantics in one syscall —
// the kernel checks "destination absent" and renames atomically, so there
// is no check-then-act window like `fileExists` followed by `moveItem`.)

import Darwin
import Foundation
import os

private let publishLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

enum DerivativeOutputPublish {

    /// What to do when a file already has the output's name.
    enum ExistingFilePolicy: Sendable, Equatable {
        /// Leave it alone; publish beside it. `reason` is said in the log
        /// and the job's summary.
        case keep(reason: String)
        /// The user chose Replace and the Master Archive rule allowed it:
        /// the existing file goes to the Trash after the new output is
        /// present, then the new output takes the name.
        case replaceViaTrash
    }

    enum Outcome: Sendable, Equatable {
        /// The name was free.
        case published(URL)
        /// The name was taken and kept; the new file landed at `url`.
        case publishedBeside(URL, keptExisting: URL, reason: String)
        /// The previous file went to the Trash (`trashedTo`, when the
        /// system reports it) and the new file took the name.
        case replaced(URL, trashedTo: URL?)

        var url: URL {
            switch self {
            case .published(let u), .publishedBeside(let u, _, _), .replaced(let u, _): return u
            }
        }
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// The Trash step. Task-local test seam so tests never fill the
    /// user's real Trash; production = `FileManager.trashItem`.
    @TaskLocal static var trashItem: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// The marker every in-flight partial carries. FilesystemWalker skips
    /// any name containing it, so a crash-leftover partial is never
    /// catalogued (pinned by a test against the walker's source).
    static let partialMarker = ".vs-partial."

    /// `<stem>.<8 hex>.vs-partial.<ext>` beside `output`: unique per run
    /// (two jobs, or a stale partial from a crash, never share a name),
    /// same directory (the publish is a same-volume rename), and the final
    /// extension kept so ffmpeg still infers the muxer. The one naming rule
    /// Combine uses too (PartialFileNaming).
    static func uniquePartialURL(for output: URL) -> URL {
        PartialFileNaming.uniquePartialURL(for: output)
    }

    /// Reserve this run's partial beside `output` — O_CREAT|O_EXCL AND
    /// registered live in the shared registry, so no stale-partial sweep
    /// (Combine's or Transcode's) touches it while the job runs, however
    /// long it is paused. The caller releases it (`PartialFileNaming.
    /// unregisterLive`) when the job ends; `publish` releases it on success.
    static func reservePartial(for output: URL) throws -> URL {
        do {
            return try PartialFileNaming.reserve(for: output)
        } catch let failure as PartialFileNaming.Failure {
            throw Failure(message: failure.message)
        }
    }

    /// A finished encode that could not be published must survive: moved
    /// off the partial pattern to `<stem>.<token>.vs-kept.<ext>` (RENAME_EXCL,
    /// never overwriting) so no stale sweep — 24 h later, any job's — can
    /// remove it. The one shared helper Combine uses too. Returns where the
    /// file now is (the partial itself if even that rename failed).
    static func keepUnpublished(_ partial: URL) -> URL {
        PartialFileNaming.keepUnpublished(partial, renameNoClobber: renameNoClobber)
    }

    /// Finder-style free-name candidate: "name 2.ext", "name 3.ext", …
    static func besideURL(for url: URL, attempt n: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Atomic no-clobber rename. true = renamed; false = the destination
    /// exists (nothing changed); throws on any other failure.
    static func renameNoClobber(_ source: String, _ destination: String) throws -> Bool {
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return true }
        let e = errno
        if e == EEXIST { return false }
        throw Failure(message: "rename to \((destination as NSString).lastPathComponent) failed: "
                      + String(cString: strerror(e)) + " (errno \(e))")
    }

    /// Publish `partial` as `final` under `policy`. DISK I/O — call it off
    /// the main thread. Throws only when nothing could be published (the
    /// partial is then still at its own name for the caller to clean up).
    static func publish(partial: String, as final: URL,
                        policy: ExistingFilePolicy,
                        archiveCheck: ArchiveRemovalCheck?,
                        trash: @Sendable (URL) throws -> URL?) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partial) else {
            throw Failure(message: "the finished output is missing (\((partial as NSString).lastPathComponent))")
        }
        // Published (the partial name is gone) ⇒ release the reservation.
        defer {
            if !fm.fileExists(atPath: partial) {
                PartialFileNaming.unregisterLive(URL(fileURLWithPath: partial))
            }
        }
        if try renameNoClobber(partial, final.path) { return .published(final) }

        // The name is taken.
        var keepReason: String
        switch policy {
        case .keep(let reason):
            keepReason = reason
        case .replaceViaTrash:
            if let note = archiveCheck?.refusalNote(forPath: final.path) {
                // The file's OWN volume is the Master Archive's (a path
                // that hid it, or a volume mounted since the policy).
                keepReason = note
            } else if !fm.fileExists(atPath: partial) {
                throw Failure(message: "the finished output vanished before it could replace \(final.lastPathComponent)")
            } else {
                switch try trashThenTake(partial: partial, final: final, trash: trash) {
                case .taken(let outcome): return outcome
                case .keep(let reason): keepReason = reason
                }
            }
        }
        for n in 2...200 {
            let candidate = besideURL(for: final, attempt: n)
            if try renameNoClobber(partial, candidate.path) {
                return .publishedBeside(candidate, keptExisting: final, reason: keepReason)
            }
        }
        throw Failure(message: "no free name beside \(final.lastPathComponent) after 199 tries")
    }

    private enum TrashStep {
        case taken(Outcome)
        case keep(String)
    }

    /// Replace: Trash the previous file, logging it BEFORE the rename, then
    /// take its name. A rename that then throws says where the previous
    /// file went — it is in the Trash, not lost.
    private static func trashThenTake(partial: String, final: URL,
                                      trash: @Sendable (URL) throws -> URL?) throws -> TrashStep {
        let trashedTo: URL?
        do {
            trashedTo = try trash(final)
        } catch {
            return .keep("the previous file could not be moved to the Trash (\(error.localizedDescription))")
        }
        let whereTo = trashedTo?.path ?? "the Trash"
        let line = "publish: moved the previous \(final.lastPathComponent) to \(whereTo); the new output takes its name next"
        publishLog.notice("\(line, privacy: .public)")
        appLog.write(line)
        do {
            if try renameNoClobber(partial, final.path) { return .taken(.replaced(final, trashedTo: trashedTo)) }
        } catch {
            throw Failure(message: "\(error.localizedDescription) — the previous \(final.lastPathComponent) is in the Trash at \(whereTo); the new output is still at \(partial)")
        }
        return .keep("another file took the name while the previous one was moved to the Trash (it is at \(whereTo))")
    }

    // MARK: Crash leftovers

    /// Partials of THIS output name (`<stem>.<8 hex>.vs-partial.<ext>`)
    /// left by a crash or force-quit, older than `olderThan`. Pure name +
    /// date test — exposed for tests. (A running job's partial is also
    /// protected by the live registry, which the sweep checks first.)
    static func isStalePartial(name: String, of output: URL, modified: Date,
                               now: Date, olderThan: TimeInterval) -> Bool {
        PartialFileNaming.isPartialName(name, of: output)
            && now.timeIntervalSince(modified) > olderThan
    }

    /// Remove stale partials of `output` in its folder; returns their
    /// names. Goes through the ONE sweep Combine uses too
    /// (PartialFileNaming.sweepStale): never a partial reserved by a running
    /// job (either kind), regular files only, the shared 24 h threshold,
    /// each removal logged with its size as swept by "transcode". Only this
    /// app's own incomplete encodes match (the scanner never catalogues a
    /// `.vs-partial.` name). DISK I/O — off-main.
    @discardableResult
    static func sweepStalePartials(beside output: URL, olderThan: TimeInterval = PartialFileNaming.staleThreshold,
                                   now: Date = Date()) -> [String] {
        let dir = output.deletingLastPathComponent()
        let result = PartialFileNaming.sweepStale(in: dir, job: "transcode", olderThan: olderThan, now: now,
                                                  matching: { PartialFileNaming.isPartialName($0, of: output) })
        let swept = result.removed.map(\.name)
        if !swept.isEmpty {
            let line = "publish: removed \(swept.count) stale partial(s) left by an interrupted run beside \(output.lastPathComponent): \(swept.joined(separator: ", "))"
            publishLog.notice("\(line, privacy: .public)")
            appLog.write(line)
        }
        return swept
    }
}
