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

    /// `<stem>.<8 hex>.vs-partial.<ext>` beside `output`: unique per run
    /// (two jobs, or a stale partial from a crash, never share a name),
    /// same directory (the publish is a same-volume rename), and the final
    /// extension kept so ffmpeg still infers the muxer.
    static func uniquePartialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        let token = UUID().uuidString.prefix(8).lowercased()
        return output.deletingPathExtension()
            .appendingPathExtension(String(token))
            .appendingPathExtension("vs-partial")
            .appendingPathExtension(ext)
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
                do {
                    let trashedTo = try trash(final)
                    if try renameNoClobber(partial, final.path) { return .replaced(final, trashedTo: trashedTo) }
                    keepReason = "another file took the name while the previous one was moved to the Trash"
                } catch let failure as Failure {
                    throw failure
                } catch {
                    keepReason = "the previous file could not be moved to the Trash (\(error.localizedDescription))"
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
}
