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
    // The semantics are deliberately "is the VOLUME mounted?", not "does this
    // specific file exist?":
    //   - Cache key is the volume root (/Volumes/X). All files on /Volumes/X
    //     share one reachability bit; per-file existence is a different
    //     concern (use FileManager.fileExists for that).
    //   - The cached value is computed by stat()'ing the VOLUME ROOT, not the
    //     specific file path. Before this fix the cache key was per-volume but
    //     the stat target was the file path, so during Verify or Scan passes
    //     the per-volume bit flipped many times per second as different files
    //     happened to be missing/present — driving an italics flicker on every
    //     catalog row (issue: italics flicker on Verify/Scan).
    //   - TTL is short (5s) so a yanked drive flips to offline quickly. Mount/
    //     unmount notifications still call `invalidateCache()` for immediate
    //     propagation.
    //
    // For paths NOT under /Volumes (internal disk, e.g. /Users/rickb/...),
    // fall back to caching/stat'ing by full path — internal paths don't have
    // the multi-file-on-one-mount aggregation problem.
    nonisolated(unsafe) private static var cache: [String: (reachable: Bool, expiresAt: CFAbsoluteTime)] = [:]
    private static let cacheLock = OSAllocatedUnfairLock()
    private static let cacheTTL: CFAbsoluteTime = 5.0

    /// Drop all cached entries. Call after volume mount/unmount notifications.
    static func invalidateCache() {
        cacheLock.withLock { cache.removeAll() }
    }

    /// True if the volume containing `path` is currently mounted. For paths
    /// under `/Volumes/X/...` this answers "is /Volumes/X mounted right now?"
    /// — independent of whether the specific file exists. For internal paths
    /// (not under /Volumes) it falls back to a per-path existence check, which
    /// is the right answer when there's no separable "volume" to ask about.
    ///
    /// Backed by a 5-second cache (see comment on `cache` above). First call
    /// for a volume pays the stat cost; repeats within the TTL return instantly.
    ///
    /// Note: if you need "does this specific file exist?", use
    /// `FileManager.default.fileExists(atPath:)` directly — that's a different
    /// question from this one.
    static func isReachable(path: String) -> Bool {
        guard !path.isEmpty else { return false }

        let key = cacheKey(forPath: path)
        let now = CFAbsoluteTimeGetCurrent()
        if let hit = cacheLock.withLock({ cache[key] }), hit.expiresAt > now {
            return hit.reachable
        }

        // Cache miss — stat the right target. For /Volumes paths, stat the
        // volume root; for everything else, stat the original path.
        // `key` already IS the volume root for /Volumes paths, so we can
        // reuse it as the stat target.
        let statTarget = key
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: statTarget, isDirectory: &isDir)
        let reachable: Bool
        if exists {
            reachable = true
        } else {
            // checkResourceIsReachable handles a few cases fileExists doesn't,
            // particularly bookmarked URLs and quick-existence checks on /Volumes.
            reachable = (try? URL(fileURLWithPath: statTarget).checkResourceIsReachable()) ?? false
        }
        cacheLock.withLock { cache[key] = (reachable, now + cacheTTL) }
        return reachable
    }

    /// Cache key (and, for /Volumes paths, the stat target) for `isReachable`.
    /// For paths under /Volumes, this is the volume root "/Volumes/<name>".
    /// For internal paths, falls back to the full path.
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
        // /Volumes/<X>/... → "X"
        if comps.count >= 3, comps[1] == "Volumes" {
            return comps[2]
        }
        // /Users/<X>/... → "X" (home folder name)
        if comps.count >= 3, comps[1] == "Users" {
            return comps[2]
        }
        // Other paths: use the top-level directory as the label
        // e.g. /private/tmp/x.mov → "private", /opt/media/x.mov → "opt"
        if comps.count >= 3 {
            return comps[1]
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// Disambiguating display label for any path: volume name alone for
    /// whole-volume scans, "Volume > Folder" for subfolder scans. Mirrors
    /// `VideoRecord.displayVolumeLabel` for paths that don't have a captured
    /// scan context yet — scan targets, menu items, sidebar entries.
    ///
    /// Resolves the volume name from `URL.resourceValues(forKeys:
    /// [.volumeNameKey])` when the path is reachable — that's the OS's
    /// user-visible volume name ("Macintosh HD", "M4drive", "MyBook3Terabytes").
    /// When the path is offline or URLResourceValues fails, falls back to
    /// `volumeName(forPath:)`'s path-string heuristic.
    ///
    /// The subfolder portion comes from `ScanContext.subfolderLabel` — nil
    /// for volume roots, the last component otherwise. Same composition
    /// rules as `displayVolumeLabel`:
    ///   - empty folder → just the volume name
    ///   - folder == volume name → just the volume (no " > " duplication)
    ///   - empty volume → fall back to the folder name
    ///
    /// Examples (assuming a boot disk named "M4drive"):
    ///   "/Volumes/MyBook"               → "MyBook"
    ///   "/Volumes/M4drive/rickb"        → "M4drive > rickb"
    ///   "/Users/rickb/Movies"           → "M4drive > Movies"
    ///   "/Users/rickb"                  → "M4drive > rickb"
    ///   "/"                             → "" (no useful label)
    ///
    /// Callers that need the raw path-string label (for legacy-record
    /// fallbacks, internal logic, or "is this duplicate on the same
    /// volume" comparisons) should keep using `volumeName(forPath:)`.
    static func displayLabel(forPath path: String) -> String {
        let vol = resolvedVolumeName(forPath: path)
        let folder = ScanContext.subfolderLabel(forScanRootPath: path) ?? ""
        if folder.isEmpty || folder == vol {
            return vol
        }
        if vol.isEmpty {
            return folder
        }
        return "\(vol) > \(folder)"
    }

    /// Volume name from URLResourceValues when available, with fallback to
    /// the path-string heuristic. Used by `displayLabel(forPath:)`.
    private static func resolvedVolumeName(forPath path: String) -> String {
        guard !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: path)
        if let vals = try? url.resourceValues(forKeys: [.volumeNameKey]),
           let name = vals.volumeName, !name.isEmpty {
            return name
        }
        return volumeName(forPath: path)
    }
}
