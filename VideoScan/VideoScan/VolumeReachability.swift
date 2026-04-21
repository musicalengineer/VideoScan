// VolumeReachability.swift
// Cheap synchronous checks for whether a path is currently mounted/readable,
// plus a tiny helper to derive a friendly volume name for offline messaging.
//
// VideoScanModel observes NSWorkspace mount/unmount notifications and refreshes
// per-target reachability — see VideoScanModel.installVolumeMountObservers().

import Foundation

enum VolumeReachability {
    /// True if `path` exists and is reachable right now. Empty paths return
    /// false. Network volume paths return false when the share is unmounted.
    static func isReachable(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if exists { return true }
        // checkResourceIsReachable handles a few cases fileExists doesn't,
        // particularly bookmarked URLs and quick-existence checks on /Volumes.
        return (try? URL(fileURLWithPath: path).checkResourceIsReachable()) ?? false
    }

    /// Best-effort friendly name for a path's owning volume. For
    /// "/Volumes/MediaArchive/clips/foo.mov" → "MediaArchive".
    /// For internal paths or anything not under /Volumes, returns the last
    /// component of the path itself.
    /// True if the path resides on a network filesystem (SMB, NFS, AFP, WebDAV).
    static func isNetworkVolume(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return false }
        let fsType = withUnsafePointer(to: &buf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return ["smbfs", "nfs", "afpfs", "webdav"].contains(fsType)
    }

    static func volumeName(forPath path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            return comps[2]
        }
        return (path as NSString).lastPathComponent
    }
}
