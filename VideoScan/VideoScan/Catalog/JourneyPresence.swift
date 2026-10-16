// JourneyPresence.swift
// The File Journey's last event is a VERIFIED presence, not a path echo
// (Rick 2026-10-16: the sheet said "Now at /Users/rickb/Movies/…" for a
// dangling symlink). `probe` asks the disk with lstat + stat — a link is
// called a link, a dead link is called gone — and `currentSentence` turns
// the answer into the words, pointing at the archived copy when there is
// one and at Catalog Status ▸ Fix Links when there is not.
//
// Unknown is a legal answer; a guess is not (integrity_first §2, codex
// 2026-10-16): only ENOENT / ENOTDIR mean "nothing is there". A folder we
// may not read, a drive that will not answer, a timed-out mount — those
// say nothing either way, and the words say so ("presence unknown") with
// no Fix Links offer. The archived copy's presence is reported in its own
// words, never reduced to "there / not there".
//
// Pure words over a value; the disk calls are `probe` (and the device
// lookups it makes for ancestor links), made once per sheet open — never
// in a view body.

import Foundation

enum JourneyPresence: Equatable {
    /// A regular file is there.
    case regularFile
    /// A regular file is there, reached through a folder that is a link
    /// onto another disk (`at` is that folder).
    case regularFileThroughLink(at: String)
    /// The last component is a link and its target is a regular file.
    case linkToFile(target: String)
    /// The last component is a link and nothing is at its target.
    case brokenLink(target: String)
    /// The last component is a link whose target could not be checked for
    /// a reason other than "nothing there" (`reason` is the errno's words).
    case linkTargetUnknown(target: String, reason: String)
    /// Something is at the path, but not a file (a folder, a device).
    case notAFile
    /// Nothing is at the path.
    case missing
    /// The path's /Volumes/<name> is not mounted — not "gone", just away.
    case volumeOffline(volume: String)
    /// The disk would not answer (Permission denied, an I/O error, a
    /// timed-out mount…): nothing is known either way.
    case unknown(reason: String)

    /// Is a file actually there to open?
    var isPresent: Bool {
        switch self {
        case .regularFile, .regularFileThroughLink, .linkToFile: return true
        case .brokenLink, .linkTargetUnknown, .notAFile, .missing, .volumeOffline, .unknown: return false
        }
    }

    /// Nothing is known either way — never to be drawn as "gone".
    var isUnknown: Bool {
        switch self {
        case .unknown, .linkTargetUnknown: return true
        default: return false
        }
    }

    // MARK: Probe (lstat + stat)

    /// "Which disk is the thing at this path on?" — `stat` (follows links).
    typealias DeviceLookup = (String) -> dev_t?

    /// Ask the disk about `path`. `isVolumeMounted` and `device` are
    /// injectable for tests (the test disk is one device).
    static func probe(_ path: String,
                      isVolumeMounted: (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) },
                      device: DeviceLookup = deviceNumber) -> JourneyPresence {
        guard !path.isEmpty else { return .missing }
        var leaf = stat()
        guard lstat(path, &leaf) == 0 else {
            let err = errno
            guard isNothingThere(err) else { return .unknown(reason: words(for: err)) }
            if path.hasPrefix("/Volumes/"), !isVolumeMounted(path) {
                return .volumeOffline(volume: volumeName(path))
            }
            return .missing
        }
        if (leaf.st_mode & S_IFMT) == S_IFLNK { return leafLink(path) }
        guard (leaf.st_mode & S_IFMT) == S_IFREG else { return .notAFile }
        if let folder = linkedAncestorOnAnotherDisk(of: path, device: device) {
            return .regularFileThroughLink(at: folder)
        }
        return .regularFile
    }

    /// The last component is a link: a file at its target, nothing there,
    /// something else there, or a target the disk would not describe.
    private static func leafLink(_ path: String) -> JourneyPresence {
        let target = linkTarget(path)
        var real = stat()
        if stat(path, &real) == 0 {
            return (real.st_mode & S_IFMT) == S_IFREG ? .linkToFile(target: target) : .notAFile
        }
        let err = errno
        return isNothingThere(err) ? .brokenLink(target: target) : .linkTargetUnknown(target: target, reason: words(for: err))
    }

    /// Only these two errors say "nothing is there". Everything else
    /// (EACCES, EPERM, EIO, ETIMEDOUT, ENXIO, ELOOP…) says "could not look".
    private static func isNothingThere(_ err: Int32) -> Bool {
        err == ENOENT || err == ENOTDIR
    }

    /// The system's own words for an errno ("Permission denied").
    private static func words(for err: Int32) -> String {
        String(cString: strerror(err))
    }

    private static func linkTarget(_ path: String) -> String {
        do { return try FileManager.default.destinationOfSymbolicLink(atPath: path) }
        catch { return "(a target that could not be read)" }
    }

    /// The disk holding what is at `path` (links followed), or nil when
    /// the disk would not say.
    static func deviceNumber(_ path: String) -> dev_t? {
        var sb = stat()
        return stat(path, &sb) == 0 ? sb.st_dev : nil
    }

    /// The first ancestor folder that is a symlink whose target lives on a
    /// DIFFERENT disk than the folder holding the link (a ~/Movies that
    /// really lives on an external drive). Same-disk plumbing links
    /// (/var → /private/var) are not news. The comparison is the link's
    /// CONTAINING folder against its resolved target — never the file's
    /// own disk, which is always the target's (codex 2026-10-16).
    static func linkedAncestorOnAnotherDisk(of path: String, device: DeviceLookup = deviceNumber) -> String? {
        var prefix = ""
        for part in path.split(separator: "/").dropLast() {
            let holder = prefix.isEmpty ? "/" : prefix
            prefix += "/" + part
            var sb = stat()
            guard lstat(prefix, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFLNK else { continue }
            guard let holderDisk = device(holder), let targetDisk = device(prefix) else { continue }
            if holderDisk != targetDisk { return prefix }
        }
        return nil
    }

    static func volumeName(_ path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 3)
        return parts.count >= 2 && parts[0] == "Volumes" ? String(parts[1]) : path
    }

    // MARK: Words

    /// The archived copy's path and its own presence, when the row has one.
    struct ArchivedCopy: Equatable {
        let path: String
        let presence: JourneyPresence
    }

    /// The last timeline event's sentence.
    static func currentSentence(path: String, presence: JourneyPresence,
                                archivedCopy: ArchivedCopy?) -> String {
        switch presence {
        case .regularFile:
            return "Now at \(path)"
        case .regularFileThroughLink(let folder):
            return "Now at \(path) — reached through a link at \(folder)"
        case .linkToFile(let target):
            return "Now at \(path) — a link to \(target), where the file is"
        case .brokenLink(let target):
            return absent("Not at \(path) — it is a link to \(target), which is gone", archivedCopy)
        case .missing:
            return absent("Not at \(path) — the file is gone", archivedCopy)
        case .notAFile:
            return absent("Not at \(path) — something else is there now, not a file", archivedCopy)
        case .volumeOffline(let volume):
            return "Not reachable — \(volume) is not connected (the file may well still be there)"
        case .unknown(let reason):
            return unknown("Could not check \(path): \(reason)", archivedCopy)
        case .linkTargetUnknown(let target, let reason):
            return unknown("Could not check \(path): it is a link to \(target), and that could not be checked: \(reason)", archivedCopy)
        }
    }

    /// A file that is NOT there: the archived copy's words, or the Fix
    /// Links door when there is no copy.
    private static func absent(_ head: String, _ copy: ArchivedCopy?) -> String {
        guard let copy else {
            return head + " · Catalog Status ▸ Fix Links can relink or forget this row"
        }
        return head + " · " + copyWords(copy)
    }

    /// A file we could not look at: no "gone", no Fix Links — the copy's
    /// words are still worth having.
    private static func unknown(_ head: String, _ copy: ArchivedCopy?) -> String {
        let tail = copy.map { " · " + copyWords($0) } ?? ""
        return head + " — presence unknown" + tail
    }

    /// The archived copy's presence in ITS words — on an unplugged drive,
    /// unreadable, there, or not at its path. Never "not there either".
    static func copyWords(_ copy: ArchivedCopy) -> String {
        switch copy.presence {
        case .regularFile, .regularFileThroughLink, .linkToFile:
            return "the archived copy is at \(copy.path)"
        case .volumeOffline(let volume):
            return "the archived copy is on \(volume), which is not connected"
        case .unknown(let reason), .linkTargetUnknown(_, let reason):
            return "could not check the archived copy at \(copy.path): \(reason)"
        case .brokenLink, .missing, .notAFile:
            return "the archived copy is not at its path (\(copy.path)) — run Verify Archive"
        }
    }
}
