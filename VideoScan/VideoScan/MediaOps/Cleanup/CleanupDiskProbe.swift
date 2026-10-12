// CleanupDiskProbe.swift
// The disk half of Cleanup's PLAN: what one catalog path is right now
// (CleanupDiskFacts). Read-only — lstat, realpath and one O_RDONLY open per
// path (FileIdentityStamp.capture). Blocking: called only off the main actor
// (VideoScanModel.buildCleanupPlan), never from a view.
//
// Rule 3 of the design ("ambiguous identity means skip") lives partly here:
//   - not a plain file (a symlink, a folder, a FIFO) → .notRegularFile;
//   - the path runs through a symlinked folder, so the file's real name is
//     another path (the 27 ~/Movies links) → .throughLink. Compared after
//     standardizing both sides; a case-only spelling of a real path on a
//     case-insensitive volume also reads as "another name" here, and is
//     caught again by the planner's same-inode index.
//
// (For Rick: `lstat` ≈ stat that does not follow a final symlink; `realpath`
// resolves every link on the way — the same POSIX calls you know from C.)

import Darwin
import Foundation
import VideoScanCore

enum CleanupDiskProbe {

    /// The facts for `path` now. `driveOnline` is the reachability seam
    /// (tests answer "not connected" without unplugging anything).
    nonisolated static func facts(for path: String,
                                  driveOnline: (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) })
        -> CleanupDiskFacts {
        guard !path.isEmpty else { return .missing }
        if VideoScanModel.isExternalVolumePath(path), !driveOnline(path) { return .driveNotConnected }
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .notRegularFile }
        guard isOwnRealPath(path) else { return .throughLink }
        guard let stamp = FileIdentityStamp.capture(path: path) else { return .missing }
        return .file(stamp)
    }

    /// Is the /Volumes mount holding `path` present RIGHT NOW — asked of the
    /// kernel, no cache: "/Volumes/<name>" exists and is a mount point (its
    /// device number differs from /Volumes's own, the classic ismount
    /// test), so a stale folder of that name on the boot disk is not a
    /// drive. False for a path not under /Volumes.
    nonisolated static func isMountPresent(forPath path: String) -> Bool {
        let comps = (path as NSString).pathComponents
        guard comps.count >= 3, comps[1] == "Volumes" else { return false }
        var root = stat(), parent = stat()
        guard stat("/Volumes/\(comps[2])", &root) == 0, stat("/Volumes", &parent) == 0 else { return false }
        return (root.st_mode & S_IFMT) == S_IFDIR && root.st_dev != parent.st_dev
    }

    /// True when resolving every link on the way gives back `path` itself,
    /// byte for byte. (Deliberately NOT `standardizingPath`, which rewrites
    /// "/private/var/…" to "/var/…" — itself a link — and would hide one.)
    nonisolated static func isOwnRealPath(_ path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
    }
}
