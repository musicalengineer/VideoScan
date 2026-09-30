// PartialFileNaming.swift
//
// The ONE mechanism for "a file an ffmpeg job is still writing":
//   <stem>.<8 hex>.vs-partial.<ext>
// beside the final destination. Combine (CombineOutputPublish) and
// Transcode (DerivativeOutputPublish) both go through here:
//
//   reserve(for:)   O_CREAT|O_EXCL the unique name AND register it live
//   remove(_:)      unlink(2) a reserved partial (refuses any other name,
//                   a directory, and a PROTECTED finished output), unregister
//   keepUnpublished protect a verified-but-unpublished output, then move it
//                   OFF the pattern (`.vs-kept.`, never overwriting)
//   unregisterLive  on publish / keep / job end
//   sweepStale(…)   the one crash-leftover sweep both jobs use: skips
//                   anything live in this process AND anything protected on
//                   disk, exact pattern only, regular files only, one
//                   threshold (24 h), each removal logged with its size and
//                   the job that swept it
//
// Why one mechanism (fix/one-partial-registry, 2026-09-22): the two jobs
// had separate sweeps with different thresholds (6 h vs 24 h), and only
// Combine registered its partials. A PAUSED Transcode's partial (ffmpeg
// stopped ⇒ mtime frozen) in a folder Combine also wrote to was removed by
// Combine's 6 h sweep, and Transcode's sweep ignored the registry. Damage
// was a failed job, never a catalog file — but it must not happen.
//
// Finished-but-unpublished outputs (codex #1642, 2026-09-23): keepUnpublished
// used to release the reservation even when its rename failed or the kept
// name was taken — the finished output kept its `.vs-partial.` name, and 24 h
// later the sweep deleted it. Now, BEFORE any rename, it writes a durable
// marker `<partial name>.keep` (O_EXCL) beside the output; the sweep and
// remove() refuse any partial that has one, in this process or after a
// restart. If even the marker can't be written, the output is PINNED in
// the process-wide registry (a job's unregisterLive does not un-pin it).
//
// (For Rick: `live` is a process-wide std::map<path, (dev, ino)> guarded by
// an os_unfair_lock — OSAllocatedUnfairLock is Swift's Sendable wrapper.)

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

    /// How many kept names (`.vs-kept.`, `-2.vs-kept.`, …) to try before
    /// leaving a finished output protected in place.
    static let keptNameAttempts = 50

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

    /// The n-th kept name for a partial: n == 1 → `<stem>.<tok>.vs-kept.<ext>`,
    /// n > 1 → `<stem>.<tok>-<n>.vs-kept.<ext>`. Never a partial name (so no
    /// sweep matches it), extension kept (players still open it).
    static func keptURL(for partial: URL, attempt n: Int) -> URL {
        var parts = partial.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 4 {
            if n > 1 { parts[parts.count - 3] += "-\(n)" }
            parts[parts.count - 2] = "vs-kept"
        }
        return partial.deletingLastPathComponent().appendingPathComponent(parts.joined(separator: "."))
    }

    // MARK: live registry

    /// A file's identity: (st_dev, st_ino). The registry matches live
    /// partials by identity, NOT by path spelling — /var vs /private/var,
    /// firmlinks, a case-insensitive volume reached with different case all
    /// name the same file (QA 2026-09-22). The path is kept for logging and
    /// for unregistering after the file is gone.
    struct FileID: Hashable, Sendable {
        let dev: UInt64
        let ino: UInt64
    }

    static func fileID(_ url: URL) -> FileID? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileID(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
    }

    struct LiveSet: Sendable {
        /// standardized path at registration → identity (nil when the file
        /// did not exist yet; then the path is the only key).
        var byPath: [String: FileID?] = [:]
        var ids: Set<FileID> = []
        /// Finished outputs kept in place that could NOT be protected on
        /// disk (codex #1642): live for the rest of the process whatever
        /// unregisterLive is called with.
        var pinnedPaths: Set<String> = []
        var pinnedIDs: Set<FileID> = []
    }

    /// Partials reserved by running jobs in THIS process. A sweep skips
    /// anything listed here regardless of age. In-process only: a second
    /// VideoScan process would not see these (it would still need the 24 h
    /// threshold to pass); a cross-process guard (flock on the partial) is
    /// a possible follow-up. Finished outputs are protected across
    /// processes by their on-disk `.keep` marker instead.
    static let live = OSAllocatedUnfairLock(initialState: LiveSet())

    static func registerLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        let id = fileID(url)
        live.withLock { set in
            set.byPath[key] = .some(id)
            if let id { set.ids.insert(id) }
        }
    }

    /// Releases a reservation. Never un-pins a kept output.
    static func unregisterLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        live.withLock { set in
            if let entry = set.byPath.removeValue(forKey: key), let id = entry {
                set.ids.remove(id)
            }
        }
    }

    /// Live for the rest of the process (see LiveSet.pinnedPaths).
    static func pin(_ url: URL) {
        let key = url.standardizedFileURL.path
        let id = fileID(url)
        live.withLock { set in
            set.pinnedPaths.insert(key)
            if let id { set.pinnedIDs.insert(id) }
        }
    }

    /// Live if this FILE (dev + ino) was reserved or pinned — under any
    /// spelling of its path — or, for a registration made before the file
    /// existed, if the path matches.
    static func isLive(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        let id = fileID(url)
        return live.withLock { set in
            if set.byPath[key] != nil || set.pinnedPaths.contains(key) { return true }
            if let id { return set.ids.contains(id) || set.pinnedIDs.contains(id) }
            return false
        }
    }

    // MARK: protection marker (finished outputs — survives restart)

    /// `<partial name>.keep` beside the partial. Not a partial name itself
    /// (its last component is `keep`), so no sweep can match it, and the
    /// scanner never catalogues it (the name contains `.vs-partial.`).
    static func protectionMarkerURL(for partial: URL) -> URL {
        partial.deletingLastPathComponent().appendingPathComponent(partial.lastPathComponent + ".keep")
    }

    /// True when a `.keep` marker (any file type) sits beside `partial`.
    static func isProtected(_ partial: URL) -> Bool {
        var st = stat()
        return lstat(protectionMarkerURL(for: partial).path, &st) == 0
    }

    /// Create the marker with O_CREAT|O_EXCL. An existing marker counts
    /// (the output is already protected). Returns false — logged — when it
    /// could not be created.
    private static func writeProtectionMarker(for partial: URL) -> Bool {
        let markerURL = protectionMarkerURL(for: partial)
        let fd = open(markerURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 {
            let e = errno
            if e == EEXIST { return true }
            partialLog.error("could not protect \(partial.path, privacy: .public): \(markerURL.lastPathComponent, privacy: .public) not created: \(String(cString: strerror(e)), privacy: .public) (errno \(e))")
            return false
        }
        let note = "VideoScan kept a FINISHED output that could not be published:\n  \(partial.path)\n"
            + "This file stops VideoScan's stale-partial cleanup from ever removing it. "
            + "Rename or move the output, then this file can go.\nCreated \(Date())\n"
        let bytes = Array(note.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count {
            // The marker EXISTS, which is what protects; the note is a courtesy.
            partialLog.notice("protection marker \(markerURL.lastPathComponent, privacy: .public) created, note not fully written (errno \(errno))")
        }
        close(fd)
        return true
    }

    /// The marker of a partial that has since moved off the pattern (only
    /// called by keepUnpublished, after `partial` passed isPartialName and
    /// was renamed away — the marker protects nothing any more).
    private static func dropProtectionMarker(for partial: URL) {
        let markerPath = protectionMarkerURL(for: partial).path
        if unlink(markerPath) != 0 {
            let e = errno
            if e != ENOENT {
                partialLog.notice("left protection marker \(markerPath, privacy: .public): \(String(cString: strerror(e)), privacy: .public)")
            }
        }
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
    /// final — and for a PROTECTED partial (a finished output kept in place,
    /// codex #1642). unlink(2), never a recursive removal: a directory
    /// swapped in under a partial's name is refused (EPERM on macOS) and
    /// left intact. Already-gone is success.
    static func remove(_ url: URL) throws {
        guard isPartialName(url.lastPathComponent) else {
            throw Failure(message: "refusing to remove \(url.lastPathComponent): not a partial")
        }
        guard !isProtected(url) else {
            throw Failure(message: "refusing to remove \(url.lastPathComponent): it is a finished output VideoScan kept "
                          + "(\(protectionMarkerURL(for: url).lastPathComponent))")
        }
        defer { unregisterLive(url) }
        guard unlink(url.path) != 0 else { return }
        let e = errno
        if e == ENOENT { return }
        let line = "could not remove partial \(url.path): " + String(cString: strerror(e)) + " (errno \(e))"
        partialLog.error("\(line, privacy: .public)")
        throw Failure(message: line)
    }

    // MARK: keep (a finished output that could not be published)

    /// A verified output that could not be published must survive, now and
    /// after a restart:
    ///   1. protect it where it is — `<partial>.keep` marker (O_EXCL);
    ///   2. move it off the partial pattern with the caller's NO-CLOBBER
    ///      rename: `<stem>.<tok>.vs-kept.<ext>`, then `…<tok>-2.vs-kept…`,
    ///      … — a taken name is never overwritten, the next one is tried;
    ///   3. moved → release the reservation, drop the marker;
    ///      not moved, marker written → release; the marker protects it;
    ///      not moved, NO marker → PIN it for the life of the process and
    ///      log that it must be moved by hand before the app quits.
    /// Returns where the file is.
    static func keepUnpublished(_ partial: URL,
                                renameNoClobber: (String, String) throws -> Bool) -> URL {
        let name = partial.lastPathComponent
        guard isPartialName(name) else { return partial }
        let marked = writeProtectionMarker(for: partial)
        var lastError: String?
        for n in 1...keptNameAttempts {
            let kept = keptURL(for: partial, attempt: n)
            do {
                guard try renameNoClobber(partial.path, kept.path) else { continue }   // taken: next name
                unregisterLive(partial)
                if marked { dropProtectionMarker(for: partial) }
                let line = "kept unpublished output \(partial.path) as \(kept.lastPathComponent)"
                partialLog.notice("\(line, privacy: .public)")
                appLog.write(line)
                return kept
            } catch {
                lastError = error.localizedDescription
                break   // this drive can't move it safely — keep it where it is
            }
        }
        let why = lastError ?? "all \(keptNameAttempts) kept names are taken"
        if marked {
            unregisterLive(partial)
            let line = "kept unpublished output IN PLACE at \(partial.path) (\(why)); protected by \(protectionMarkerURL(for: partial).lastPathComponent)"
            partialLog.notice("\(line, privacy: .public)")
            appLog.write(line)
        } else {
            pin(partial)
            let line = "kept unpublished output IN PLACE at \(partial.path) (\(why)); NO protection marker could be written — "
                + "protected only until VideoScan quits: move or rename it by hand"
            partialLog.error("\(line, privacy: .public)")
            appLog.write(line)
        }
        return partial
    }

    // MARK: stale sweep (the one both jobs use)

    struct SweptPartial: Sendable, Equatable {
        let name: String
        let sizeBytes: Int64
    }

    /// Remove partials in `folder` left by a crashed/killed run: ONLY names
    /// of the exact partial pattern (further narrowed by `matching`), ONLY
    /// regular files, ONLY older than `olderThan` (modification time),
    /// NEVER one a running job in this process reserved, and NEVER a
    /// protected finished output (`.keep` marker). Each removal is logged
    /// with its size and `job` (the job whose sweep removed it).
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
            if isProtected(url) { continue }
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

// MARK: - ExclusivePublish — the one no-clobber rename

/// Give a finished file a name WITHOUT ever replacing what is there.
/// Combine, Transcode and Reformat all publish (and keep) through here.
///
///   1. `renamex_np(RENAME_EXCL)`: atomic; EEXIST if the name is taken.
///   2. RENAME_EXCL unsupported (ENOTSUP/EINVAL — exFAT, msdos, some SMB):
///      `link(2)` the file at the new name — also atomic, also EEXIST if
///      taken — then drop the old name. No check-then-act window.
///   3. Hard links unsupported too (exFAT): REFUSE. The caller keeps the
///      output where it is (protected) and says "finished but not
///      published — the drive can't publish without risk of overwriting".
///
/// There is NO fallback that renames over anything (codex #1642: the old
/// placeholder fallback lstat-checked then rename(2)d — a second writer in
/// that window was overwritten while publish reported success).
///
/// (For Rick: link(2) + unlink(2) is the classic pre-RENAME_EXCL way to do
/// an exclusive rename in C — `link` fails with EEXIST atomically.)
enum ExclusivePublish {

    /// The RENAME_EXCL syscall; 0 or an errno. Task-local test seam (an
    /// exFAT disk image can't be made in the test host).
    @TaskLocal static var renameExclSyscall: @Sendable (String, String) -> Int32 = { src, dst in
        renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// link(2); 0 or an errno. Task-local test seam.
    @TaskLocal static var linkSyscall: @Sendable (String, String) -> Int32 = { src, dst in
        link(src, dst) == 0 ? 0 : errno
    }

    /// Test seam: runs just before the fallback's publishing syscall — where
    /// codex's probe put a second writer. Production never sets it.
    @TaskLocal static var beforeFallbackPublish: (@Sendable (_ destination: String) -> Void)? = nil

    /// Said whenever a finished output is refused for lack of an exclusive
    /// primitive (tests match on it).
    static let cannotPublishSafelyNote = "the drive can't publish without risk of overwriting"

    /// link(2) errors that mean "this volume has no hard links", as
    /// opposed to an I/O or permission problem.
    static let noHardLinkErrnos: Set<Int32> = [ENOTSUP, EOPNOTSUPP, EPERM, EXDEV, EMLINK]

    enum Result: Equatable, Sendable {
        case renamed
        /// The name is taken; nothing changed. `renameExclSupported` false
        /// ⇒ this volume can't swap names exclusively (Replace must not
        /// Trash first).
        case taken(renameExclSupported: Bool)
    }

    /// true = renamed; false = the destination exists (nothing changed);
    /// throws on any other failure (the source is then still at its name).
    static func renameNoClobber(_ source: String, _ destination: String) throws -> Bool {
        try renameNoClobberDetailed(source, destination) == .renamed
    }

    static func renameNoClobberDetailed(_ source: String, _ destination: String) throws -> Result {
        let e = renameExclSyscall(source, destination)
        if e == 0 { return .renamed }
        if e == EEXIST { return .taken(renameExclSupported: true) }
        guard e == ENOTSUP || e == EINVAL else {
            throw PartialFileNaming.Failure(message: "rename to \((destination as NSString).lastPathComponent) failed: "
                                            + String(cString: strerror(e)) + " (errno \(e))")
        }
        return try publishByLink(source, destination, exclErrno: e)
    }

    private static func publishByLink(_ source: String, _ destination: String,
                                      exclErrno: Int32) throws -> Result {
        let name = (destination as NSString).lastPathComponent
        var mine = stat()
        guard lstat(source, &mine) == 0 else {
            let se = errno
            throw PartialFileNaming.Failure(message: "rename to \(name) failed: the file to publish is gone: "
                                            + String(cString: strerror(se)) + " (errno \(se))")
        }
        beforeFallbackPublish?(destination)
        let le = linkSyscall(source, destination)
        if le == EEXIST { return .taken(renameExclSupported: false) }
        if le != 0 {
            if noHardLinkErrnos.contains(le) {
                throw PartialFileNaming.Failure(message: "\(name) not published: this drive supports neither exclusive rename "
                                                + "(errno \(exclErrno)) nor hard links (errno \(le)) — \(cannotPublishSafelyNote)")
            }
            throw PartialFileNaming.Failure(message: "rename to \(name) failed: RENAME_EXCL unsupported (errno \(exclErrno)) "
                                            + "and link failed: " + String(cString: strerror(le)) + " (errno \(le))")
        }
        // `destination` is now a second name of OUR file. Drop the source
        // name — only while it is still that same file. The data is
        // published either way; a leftover source name is only a second
        // link to it (logged).
        var now = stat()
        if lstat(source, &now) == 0, now.st_dev == mine.st_dev, now.st_ino == mine.st_ino {
            if unlink(source) != 0 {
                let ue = errno
                partialLog.notice("published \(destination, privacy: .public) by link; the old name \(source, privacy: .public) could not be dropped: \(String(cString: strerror(ue)), privacy: .public)")
            }
        } else {
            partialLog.notice("published \(destination, privacy: .public) by link; \(source, privacy: .public) is no longer the published file — left alone")
        }
        return .renamed
    }
}
