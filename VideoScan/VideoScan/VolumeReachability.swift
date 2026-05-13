// VolumeReachability.swift
// Cheap synchronous checks for whether a path is currently mounted/readable,
// plus a tiny helper to derive a friendly volume name for offline messaging.
//
// VideoScanModel observes NSWorkspace mount/unmount notifications and refreshes
// per-target reachability — see VideoScanModel.installVolumeMountObservers().

import Foundation
import os.lock

enum VolumeReachability {
    // MARK: - Per-volume reachability cache (issue #87)
    //
    // The catalog Table renders one row per file, and each row's cell builder
    // calls `isReachable(path:)` synchronously inside the layout closure. With
    // a slow / sleeping / network-mounted volume, FileManager.fileExists() can
    // block the main thread for many seconds — observed beachball up to 60s
    // with 3-4 Person Finder scans driving frequent table redraws.
    //
    // Two changes mitigate that without rewriting every caller:
    //   1. Cache by VOLUME, not by full path. All files on /Volumes/Foo share
    //      one reachability bit; checking once per volume per render is the
    //      right granularity.
    //   2. TTL the cache. A reasonably short TTL (5s) keeps the UI fresh
    //      enough for "drive went away" detection while collapsing thousands
    //      of redundant stat() calls into one per volume per 5 seconds.
    //
    // The cache is invalidated explicitly by VideoScanModel on mount/unmount
    // notifications, so volume-state changes propagate immediately and don't
    // wait for the TTL.
    nonisolated(unsafe) private static var cache: [String: (reachable: Bool, expiresAt: CFAbsoluteTime)] = [:]
    private static let cacheLock = OSAllocatedUnfairLock()
    private static let cacheTTL: CFAbsoluteTime = 5.0

    /// Drop all cached entries. Call after volume mount/unmount notifications.
    static func invalidateCache() {
        cacheLock.withLock { cache.removeAll() }
    }

    /// True if `path` exists and is reachable right now. Empty paths return
    /// false. Network volume paths return false when the share is unmounted.
    ///
    /// Backed by a 5-second per-volume cache (see comment on `cache` above).
    /// First call for a volume pays the stat cost; repeats within the TTL
    /// return instantly. The cache is keyed by volume name (`volumeName(forPath:)`),
    /// so all files on the same mount share one cache slot.
    static func isReachable(path: String) -> Bool {
        guard !path.isEmpty else { return false }

        let key = cacheKey(forPath: path)
        let now = CFAbsoluteTimeGetCurrent()
        if let hit = cacheLock.withLock({ cache[key] }), hit.expiresAt > now {
            return hit.reachable
        }

        // Cache miss — pay the syscall, then cache the result.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let reachable: Bool
        if exists {
            reachable = true
        } else {
            // checkResourceIsReachable handles a few cases fileExists doesn't,
            // particularly bookmarked URLs and quick-existence checks on /Volumes.
            reachable = (try? URL(fileURLWithPath: path).checkResourceIsReachable()) ?? false
        }
        cacheLock.withLock { cache[key] = (reachable, now + cacheTTL) }
        return reachable
    }

    /// Cache key for `isReachable`. For paths under /Volumes, this is the
    /// volume name ("MediaArchive"), so every file on that mount shares one
    /// cache slot. For internal paths, falls back to the full path.
    private static func cacheKey(forPath path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            return "/Volumes/\(comps[2])"
        }
        return path
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
