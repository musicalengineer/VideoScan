// PartialFileNaming.swift
//
// The ONE mechanism for "a file an ffmpeg job is still writing":
//   <stem>.<8 hex>.vs-partial.<ext>
// beside the final destination. Combine (CombineOutputPublish) and
// Transcode (DerivativeOutputPublish) both go through here:
//
//   reserve(for:)   O_CREAT|O_EXCL the unique name AND register it live
//   remove(_:)      remove a reserved partial (refuses any other name),
//                   unregister it
//   unregisterLive  on publish / keep / job end
//   sweepStale(…)   the one crash-leftover sweep both jobs use: skips
//                   anything live in this process, exact pattern only,
//                   regular files only, one threshold (24 h), each removal
//                   logged with its size and the job that swept it
//
// Why one mechanism (fix/one-partial-registry, 2026-09-22): the two jobs
// had separate sweeps with different thresholds (6 h vs 24 h), and only
// Combine registered its partials. A PAUSED Transcode's partial (ffmpeg
// stopped ⇒ mtime frozen) in a folder Combine also wrote to was removed by
// Combine's 6 h sweep, and Transcode's sweep ignored the registry. Damage
// was a failed job, never a catalog file — but it must not happen.
//
// (For Rick: `live` is a process-wide std::set<std::string> guarded by an
// os_unfair_lock — OSAllocatedUnfairLock is Swift's Sendable wrapper.)

import Darwin
import Foundation
import os

private let partialLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

enum PartialFileNaming {

    static let marker = "vs-partial"

    /// The one stale threshold for every sweep. A running job's partial is
    /// also protected by the live registry; the threshold only matters for
    /// leftovers of a crash / force-quit — and for a job paused so long its
    /// mtime froze, so it is generous (24 h, the safer of the two old ones).
    static let staleThreshold: TimeInterval = 24 * 3600

    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    // MARK: naming

    /// `<stem>.<8 hex>.vs-partial.<ext>` beside `output`: same directory
    /// (the publish is a same-volume rename), final extension kept so
    /// ffmpeg still infers the muxer.
    static func uniquePartialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        let token = UUID().uuidString.prefix(8).lowercased()
        return output.deletingPathExtension()
            .appendingPathExtension(String(token))
            .appendingPathExtension(marker)
            .appendingPathExtension(ext)
    }

    /// True for a name `uniquePartialURL` produces — and nothing else.
    static func isPartialName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return false }
        let token = parts[parts.count - 3]
        return parts[parts.count - 2] == marker
            && !parts[0].isEmpty
            && token.count == 8
            && token.allSatisfy { $0.isHexDigit }
    }

    /// True for a partial of exactly `output`'s name (same stem, same ext).
    static func isPartialName(_ name: String, of output: URL) -> Bool {
        let stem = output.deletingPathExtension().lastPathComponent
        let suffix = ".\(marker).\(output.pathExtension)"
        guard name.hasPrefix(stem + "."), name.hasSuffix(suffix),
              name.count == stem.count + 1 + 8 + suffix.count else { return false }
        return isPartialName(name)
    }

    // MARK: live registry

    /// Partials reserved by running jobs in THIS process (standardized
    /// paths). A sweep skips anything listed here regardless of age.
    static let live = OSAllocatedUnfairLock(initialState: Set<String>())

    static func registerLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        live.withLock { _ = $0.insert(key) }
    }

    static func unregisterLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        live.withLock { _ = $0.remove(key) }
    }

    static func isLive(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return live.withLock { $0.contains(key) }
    }

    // MARK: reserve / remove

    /// Create an EMPTY partial with O_CREAT|O_EXCL so the name is ours
    /// alone before ffmpeg (`-y`) writes into it, and register it live (so
    /// no sweep — any job's — touches it). Retries on the (astronomically
    /// unlikely) token collision; throws on any other failure.
    static func reserve(for output: URL) throws -> URL {
        for _ in 0..<16 {
            let candidate = uniquePartialURL(for: output)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                registerLive(candidate)
                return candidate
            }
            let e = errno
            if e == EEXIST { continue }
            throw Failure(message: "could not create \(candidate.lastPathComponent): "
                          + String(cString: strerror(e)) + " (errno \(e))")
        }
        throw Failure(message: "no free partial name beside \(output.lastPathComponent)")
    }

    /// Remove a partial and release its reservation. Refuses (throws) for
    /// any name that is not a partial, so a caller bug can never delete a
    /// final. Already-gone is success.
    static func remove(_ url: URL) throws {
        guard isPartialName(url.lastPathComponent) else {
            throw Failure(message: "refusing to remove \(url.lastPathComponent): not a partial")
        }
        defer { unregisterLive(url) }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    // MARK: stale sweep (the one both jobs use)

    struct SweptPartial: Sendable, Equatable {
        let name: String
        let sizeBytes: Int64
    }

    /// Remove partials in `folder` left by a crashed/killed run: ONLY names
    /// of the exact partial pattern (further narrowed by `matching`), ONLY
    /// regular files, ONLY older than `olderThan` (modification time), and
    /// NEVER one a running job in this process reserved. Each removal is
    /// logged with its size and `job` (the job whose sweep removed it).
    /// DISK I/O — call off-main.
    static func sweepStale(in folder: URL, job: String,
                           olderThan: TimeInterval = staleThreshold,
                           now: Date = Date(),
                           matching: (String) -> Bool = { _ in true })
        -> (removed: [SweptPartial], errors: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return ([], []) }
        var removed: [SweptPartial] = []
        var errors: [String] = []
        for name in names.sorted() where isPartialName(name) && matching(name) {
            let url = folder.appendingPathComponent(name)
            if isLive(url) { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > olderThan else { continue }
            let size = (attrs[.size] as? Int64) ?? 0
            do {
                try remove(url)
                removed.append(SweptPartial(name: name, sizeBytes: size))
                let hours = Int(olderThan / 3600)
                let line = "\(job): removed stale partial \(url.path) (\(Formatting.humanSize(size))) — "
                    + "older than \(hours) h, not reserved by a running job"
                partialLog.notice("\(line, privacy: .public)")
                appLog.write(line)
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
                partialLog.error("\(job, privacy: .public): stale partial \(name, privacy: .public) could not be removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (removed, errors)
    }
}
