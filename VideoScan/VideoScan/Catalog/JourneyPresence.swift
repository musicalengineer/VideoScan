// JourneyPresence.swift
// The File Journey's last event is a VERIFIED presence, not a path echo
// (Rick 2026-10-16: the sheet said "Now at /Users/rickb/Movies/…" for a
// dangling symlink). `probe` asks the disk with lstat + stat — a link is
// called a link, a dead link is called gone — and `currentSentence` turns
// the answer into the words, pointing at the archived copy when there is
// one and at Catalog Status ▸ Fix Links when there is not.
//
// Pure words over a value; the one disk call is `probe`, made once per
// sheet open (never in a view body).

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
    /// Something is at the path, but not a file (a folder, a device).
    case notAFile
    /// Nothing is at the path.
    case missing
    /// The path's /Volumes/<name> is not mounted — not "gone", just away.
    case volumeOffline(volume: String)

    /// Is a file actually there to open?
    var isPresent: Bool {
        switch self {
        case .regularFile, .regularFileThroughLink, .linkToFile: return true
        case .brokenLink, .notAFile, .missing, .volumeOffline: return false
        }
    }

    // MARK: Probe (lstat + stat)

    /// Ask the disk about `path`. `isVolumeMounted` is injectable for tests.
    static func probe(_ path: String,
                      isVolumeMounted: (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }) -> JourneyPresence {
        guard !path.isEmpty else { return .missing }
        var leaf = stat()
        guard lstat(path, &leaf) == 0 else {
            if path.hasPrefix("/Volumes/"), !isVolumeMounted(path) {
                return .volumeOffline(volume: volumeName(path))
            }
            return .missing
        }
        if (leaf.st_mode & S_IFMT) == S_IFLNK {
            var real = stat()
            let target = linkTarget(path)
            if stat(path, &real) == 0, (real.st_mode & S_IFMT) == S_IFREG { return .linkToFile(target: target) }
            return .brokenLink(target: target)
        }
        guard (leaf.st_mode & S_IFMT) == S_IFREG else { return .notAFile }
        if let folder = linkedAncestorOnAnotherDisk(of: path, fileDevice: leaf.st_dev) {
            return .regularFileThroughLink(at: folder)
        }
        return .regularFile
    }

    private static func linkTarget(_ path: String) -> String {
        do { return try FileManager.default.destinationOfSymbolicLink(atPath: path) }
        catch { return "(a target that could not be read)" }
    }

    /// The first ancestor folder that is a symlink onto a DIFFERENT disk
    /// than the file (a ~/Movies that really lives on an external drive).
    /// Same-disk plumbing links (/var → /private/var) are not news.
    private static func linkedAncestorOnAnotherDisk(of path: String, fileDevice: dev_t) -> String? {
        var prefix = ""
        let parts = path.split(separator: "/").dropLast()
        for part in parts {
            prefix += "/" + part
            var sb = stat()
            guard lstat(prefix, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFLNK else { continue }
            var resolved = stat()
            if stat(prefix, &resolved) == 0, resolved.st_dev != fileDevice { return prefix }
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
        }
    }

    private static func absent(_ head: String, _ copy: ArchivedCopy?) -> String {
        guard let copy else {
            return head + " · Catalog Status ▸ Fix Links can relink or forget this row"
        }
        if copy.presence.isPresent {
            return head + " · the archived copy is at \(copy.path)"
        }
        return head + " · the archived copy should be at \(copy.path) but is not there either — run Verify Archive"
    }
}
