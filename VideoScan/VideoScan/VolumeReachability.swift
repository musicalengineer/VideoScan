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
        let info = mountInfo(forPath: path)
        return ["smbfs", "nfs", "afpfs", "webdav"].contains(info.mountType)
    }

    /// Mount-type + remote-server provenance for a path. Used by ScanContext
    /// to tag each cataloged file with how its volume was mounted at scan time.
    ///
    /// `mountType` is the raw statfs f_fstypename — "apfs", "hfs", "smbfs",
    /// "nfs", "afpfs", "webdav", "msdos", "exfat", etc. Empty if statfs fails
    /// or the path is empty.
    ///
    /// `remoteServer` is parsed from f_mntfromname for network filesystems:
    /// - SMB     `//user@host/share` or `//host/share` → "host"
    /// - NFS     `host:/export/path`                    → "host"
    /// - AFP     `afp://user@host/share`                → "host"
    /// Empty for local mounts and for anything we can't parse.
    static func mountInfo(forPath path: String) -> (mountType: String, remoteServer: String) {
        guard !path.isEmpty else { return ("", "") }
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return ("", "") }

        let fsType = withUnsafePointer(to: &buf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        let fromName = withUnsafePointer(to: &buf.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }

        let server = parseRemoteServer(fsType: fsType, mntFromName: fromName)
        return (fsType, server)
    }

    /// Parses the server name out of a statfs `f_mntfromname` string.
    /// Factored out so it's unit-testable without a real mount.
    ///
    /// Accepted forms:
    ///   SMB     `//user@host/share`, `//host/share`, `smb://host/share`
    ///   AFP     `afp://user@host/share`, `//host/share`
    ///   NFS     `host:/export/path`
    ///   WebDAV  `https://host/path`, `http://host/path`
    /// Anything local, unknown, or unparseable returns "".
    static func parseRemoteServer(fsType: String, mntFromName: String) -> String {
        switch fsType {
        case "smbfs", "afpfs":
            // Normalize off any URL-style scheme ("afp://", "smb://") — statfs
            // emits either that or a bare "//host/share" depending on the mount.
            var core = mntFromName
            for prefix in ["afp://", "smb://", "//"] {
                if core.hasPrefix(prefix) {
                    core = String(core.dropFirst(prefix.count))
                    break
                }
            }
            guard !core.isEmpty else { return "" }
            // Host is everything up to the first "/", optionally with "user@" in front.
            let hostPart: String
            if let slashIdx = core.firstIndex(of: "/") {
                hostPart = String(core[..<slashIdx])
            } else {
                hostPart = core
            }
            if let atIdx = hostPart.lastIndex(of: "@") {
                return String(hostPart[hostPart.index(after: atIdx)...])
            }
            return hostPart
        case "nfs":
            // "host:/export/path"
            guard let colonIdx = mntFromName.firstIndex(of: ":") else { return "" }
            return String(mntFromName[..<colonIdx])
        case "webdav":
            // "https://host/path" or "http://host/path"
            if let url = URL(string: mntFromName), let host = url.host {
                return host
            }
            return ""
        default:
            return ""
        }
    }

    static func volumeName(forPath path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            return comps[2]
        }
        return (path as NSString).lastPathComponent
    }
}
