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
//      two concurrent pairs can never share one.
//   2. Success + verify → publish with `renamex_np(RENAME_EXCL)`: an atomic
//      rename that FAILS if the name is taken. Never RENAME_SWAP /
//      `replaceItemAt` (the Sandbox.kext deadlock, AtomicFilePublish.swift).
//   3. Name taken → "name 2.mov", "name 3.mov", … (Finder style); the caller
//      logs it and catalogs the name actually published.
//   4. Failure / verify failure / cancel remove ONLY the partial this run
//      reserved — `removePartial` refuses any name that is not a partial.
//
// (For Rick: RENAME_EXCL ≈ link()+unlink() in one syscall — the kernel checks
// "destination absent" and renames atomically, so there is no check-then-act
// window like `fileExists` followed by `moveItem`.)
//
// UNIFY NOTE: fix/archive-protection-followups adds DerivativeOutputPublish
// (Transcode/Reformat) with the same partial naming, `besideURL`,
// `renameNoClobber` and an `Outcome` of the same shape. Once both are on
// main, `publish(partial:as:)` here is exactly
//   DerivativeOutputPublish.publish(partial:, as:, policy: .keep(reason: …),
//                                   archiveCheck: nil, trash: { _ in nil })
// and this file can shrink to `reservePartial` + `removePartial` (or move
// both into the shared helper).

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

    /// Marker every partial carries; `removePartial` refuses anything else.
    static let partialMarker = "vs-partial"

    /// `<stem>.<8 hex>.vs-partial.<ext>` beside `output`: same directory
    /// (the publish is a same-volume rename), final extension kept.
    static func uniquePartialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        let token = UUID().uuidString.prefix(8).lowercased()
        return output.deletingPathExtension()
            .appendingPathExtension(String(token))
            .appendingPathExtension(partialMarker)
            .appendingPathExtension(ext)
    }

    /// True for a name `uniquePartialURL` produces — and nothing else.
    static func isPartialName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return false }
        let marker = parts[parts.count - 2]
        let token = parts[parts.count - 3]
        return marker == partialMarker
            && token.count == 8
            && token.allSatisfy { $0.isHexDigit }
    }

    /// Create an EMPTY partial with O_CREAT|O_EXCL so the name is ours alone
    /// before ffmpeg (`-y`) writes into it. Retries on the (astronomically
    /// unlikely) token collision; throws on any other failure.
    static func reservePartial(for output: URL) throws -> URL {
        for _ in 0..<16 {
            let candidate = uniquePartialURL(for: output)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            let e = errno
            if e == EEXIST { continue }
            throw Failure(message: "could not create \(candidate.lastPathComponent): "
                          + String(cString: strerror(e)) + " (errno \(e))")
        }
        throw Failure(message: "no free partial name beside \(output.lastPathComponent)")
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

    /// Publish `partial` as `final`, or beside it when the name is taken.
    /// Never touches an existing file. Throws only when nothing could be
    /// published — the partial is then still at its own name for the caller
    /// to remove.
    static func publish(partial: String, as final: URL) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: partial) else {
            throw Failure(message: "the finished output is missing (\((partial as NSString).lastPathComponent))")
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

    /// Remove a partial this run reserved. Refuses (throws) for any name
    /// that is not a partial, so a caller bug can never delete a final.
    /// Already-gone is success.
    static func removePartial(_ url: URL) throws {
        guard isPartialName(url.lastPathComponent) else {
            throw Failure(message: "refusing to remove \(url.lastPathComponent): not a Combine partial")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

/// Test seams for the Combine pipeline. Production never sets them.
enum CombineTestSeams {
    /// Called just before ffmpeg starts, with the destination name and the
    /// file ffmpeg will actually write. Lets a test put something at the
    /// destination in the window between the pre-check and the publish
    /// (the audit's 2026-09-22 race) or cancel the job mid-mux.
    @TaskLocal static var beforeMux: (@Sendable (_ destination: URL, _ writeTarget: URL) -> Void)? = nil
}
