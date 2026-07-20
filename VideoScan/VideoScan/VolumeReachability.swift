// VolumeReachability.swift
// Cheap synchronous checks for whether a path is currently mounted/readable,
// plus a tiny helper to derive a friendly volume name for offline messaging.
//
// VideoScanModel observes NSWorkspace mount/unmount notifications and refreshes
// per-target reachability — see VideoScanModel.installVolumeMountObservers().
//
// Threading model (perf fix 2026-06-10 — stale-while-revalidate):
// `isReachable(path:)` and `displayLabel(forPath:)` are called per-row from
// SwiftUI cell builders on the MAIN thread. The old design did the
// FileManager stat / URLResourceValues disk hit synchronously on a cache
// miss — a sleeping HDD or stale SMB mount blocked the main thread for
// seconds, recurring every TTL while scrolling (the file's own history
// documents a 60 s beachball). The synchronous API now NEVER touches the
// filesystem:
//   - fresh cache hit  → return it
//   - stale cache hit  → return the stale value, refresh in the background
//   - unknown key      → /Volumes paths: HONEST answer from the kernel mount
//                        table (no disk I/O); other paths: optimistic true.
//                        Background probe scheduled either way.
// Background probes are coalesced per key, so a hung SMB stat blocks one
// utility-queue lane once — never the UI, and never twice concurrently.
// Probes that CHANGE an answer post `reachabilityDidChange` so the UI
// re-renders with the truth (2026-06-10 regression fix: at startup every
// volume ever scanned showed connected — optimistic defaults, no repaint).

import Foundation
import os.lock

// MARK: - SWRProbeCache

/// Generic stale-while-revalidate cache around a blocking probe.
///
/// `// In C++ terms: a thread-safe memoizer whose get() never blocks on the
/// expensive recompute — it serves the last known value (or a default) and
/// schedules the recompute on a worker pool.`
///
/// Semantics (the state machine the unit tests pin down):
///   - `value(forKey:missDefault:)` with a FRESH entry → cached value, no probe.
///   - With a STALE entry → cached value returned immediately; ONE background
///     probe is scheduled (coalesced — concurrent calls for the same key while
///     a probe is in flight do not stack probes).
///   - With NO entry → `missDefault` returned immediately; probe scheduled.
///   - `invalidateAll()` → next query for any key behaves like NO entry.
///
/// Instantiable (rather than static) so unit tests can construct their own
/// engine with an injected probe closure and a tiny TTL — no real volumes,
/// no shared static state to poison parallel test suites.
final class SWRProbeCache<Value>: @unchecked Sendable {
    private var entries: [String: (value: Value, expiresAt: CFAbsoluteTime)] = [:]
    private var inFlight = Set<String>()
    private let lock = OSAllocatedUnfairLock()
    private let queue: DispatchQueue
    private let ttl: CFAbsoluteTime
    private let probe: (String) -> Value
    private let valuesEqual: ((Value, Value) -> Bool)?
    private let onChange: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - label: dispatch queue label (diagnostics).
    ///   - ttl: seconds a probed value stays fresh.
    ///   - valuesEqual: equality for change detection (generic Value isn't
    ///     Equatable). Required for `onChange` to suppress no-op refreshes.
    ///   - onChange: called (on the probe queue) when a probe lands with a
    ///     value DIFFERENT from the previous entry — or fills a key that had
    ///     no entry. Lets callers repaint UI that rendered with a default
    ///     before the truth arrived (the 2026-06-10 "every volume shows
    ///     connected at startup" regression: probes corrected the cache but
    ///     nothing told SwiftUI to re-render).
    ///   - probe: the blocking check. Runs on a background utility queue,
    ///     NEVER on the caller's thread. May block for seconds (hung SMB) —
    ///     the queue is concurrent so one hung volume doesn't starve others.
    init(label: String,
         ttl: CFAbsoluteTime,
         valuesEqual: ((Value, Value) -> Bool)? = nil,
         onChange: (@Sendable (String) -> Void)? = nil,
         probe: @escaping (String) -> Value) {
        self.ttl = ttl
        self.valuesEqual = valuesEqual
        self.onChange = onChange
        self.probe = probe
        self.queue = DispatchQueue(label: label, qos: .utility, attributes: .concurrent)
    }

    /// Synchronous, non-blocking lookup. Returns the cached value (stale OK)
    /// or `missDefault` for unknown keys. Schedules a coalesced background
    /// refresh when the entry is missing or expired.
    func value(forKey key: String, missDefault: Value) -> Value {
        let now = CFAbsoluteTimeGetCurrent()
        let snapshot: (value: Value?, needsRefresh: Bool) = lock.withLockUnchecked {
            guard let hit = entries[key] else { return (nil, true) }
            return (hit.value, hit.expiresAt <= now)
        }
        if snapshot.needsRefresh {
            scheduleRefresh(forKey: key)
        }
        // `.some(probedValue)` beats the default even when Value is itself
        // an Optional and the probed value is nil — a *failed* probe result
        // is still a cached fact, distinct from "never probed".
        return snapshot.value ?? missDefault
    }

    /// Drop all entries. Next query per key returns `missDefault` and
    /// re-probes. (In-flight probes still land; they just repopulate.)
    func invalidateAll() {
        lock.withLockUnchecked { entries.removeAll() }
    }

    /// Test seam: block until every in-flight probe has landed. A barrier
    /// on the concurrent probe queue — safe to call from tests; never used
    /// in production paths.
    func awaitPendingProbes() {
        queue.sync(flags: .barrier) {}
    }

    private func scheduleRefresh(forKey key: String) {
        // Coalesce: only the first caller per key starts a probe; everyone
        // else rides on it.
        let shouldStart = lock.withLockUnchecked { inFlight.insert(key).inserted }
        guard shouldStart else { return }
        queue.async { [self] in
            let probed = probe(key)            // may block — background only
            let expires = CFAbsoluteTimeGetCurrent() + ttl
            let changed: Bool = lock.withLockUnchecked {
                let previous = entries[key]?.value
                entries[key] = (probed, expires)
                _ = inFlight.remove(key)
                guard let previous else { return true }   // first fill
                guard let eq = valuesEqual else { return false }
                return !eq(previous, probed)
            }
            if changed { onChange?(key) }      // outside the lock
        }
    }
}

enum VolumeReachability {
    // MARK: - Per-volume reachability cache (issue #87 + SWR fix 2026-06-10)
    //
    // The catalog Table renders one row per file, and each row's cell builder
    // calls `isReachable(path:)` synchronously inside the layout closure. With
    // a slow / sleeping / network-mounted volume, FileManager.fileExists() can
    // block the main thread for many seconds — observed beachball up to 60s
    // with 3-4 Person Finder scans driving frequent table redraws. The probe
    // therefore runs strictly in the background (see SWRProbeCache header).
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
    //   - First-ever query for a /Volumes path is answered HONESTLY from the
    //     kernel mount table (getmntinfo MNT_NOWAIT — reads in-kernel state,
    //     never touches the disk, microseconds). Regression fix 2026-06-10:
    //     the first SWR version answered unknown volumes with an optimistic
    //     `true` and nothing repainted when the probe corrected it — at app
    //     start every volume ever scanned showed as connected. Non-/Volumes
    //     paths (internal disk) still default optimistic-true; their probes
    //     resolve in milliseconds and the disk doesn't sleep.
    //   - When a background probe CHANGES an answer, `reachabilityDidChange`
    //     is posted so the UI re-renders with the truth (see onChange).
    //
    // For paths NOT under /Volumes (internal disk, e.g. /Users/rickb/...),
    // fall back to caching/stat'ing by full path — internal paths don't have
    // the multi-file-on-one-mount aggregation problem.

    /// Posted (on the main queue) whenever a background probe changes a
    /// reachability or volume-name answer. VideoScanModel observes this and
    /// triggers a re-render so rows drawn with a default get corrected.
    static let reachabilityDidChange =
        Notification.Name("VideoScanVolumeReachabilityDidChange")

    private static func postReachabilityDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: reachabilityDidChange, object: nil)
        }
    }

    private static let reachabilityCache = SWRProbeCache<Bool>(
        label: "Rick-Breen.VideoScan.volumeReachability.reachable",
        ttl: 5.0,
        valuesEqual: { $0 == $1 },
        onChange: { _ in postReachabilityDidChange() },
        probe: { statTarget in
            // /Volumes keys are answered from the kernel mount table — the
            // SAME source of truth as the miss-default (2026-07-20 fix). The
            // probe reads a FRESH `currentMountedRoots()`; `defaultReachability`
            // reads the cached `mountedRoots` snapshot (refreshed on first use
            // + mount/unmount invalidation), so the two can momentarily diverge
            // if a mount changes with no notification — benign under
            // stale-while-revalidate. `fileExists` returns TRUE
            // for a leftover mountpoint stub directory or a symlink (proven
            // live: `/Volumes/M4drive -> /` exists via fileExists but is NOT
            // in the mount table), which would resurrect a disconnected drive
            // as "connected" and defeat the reachable-only filter. getmntinfo
            // reads in-kernel state, never spins up a sleeping HDD.
            if statTarget.hasPrefix("/Volumes/") {
                return currentMountedRoots().contains(statTarget)
            }
            // Non-/Volumes (internal) keys: existence IS the right question —
            // there's no separable "volume" to ask the mount table about.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: statTarget, isDirectory: &isDir) {
                return true
            }
            // checkResourceIsReachable handles a few cases fileExists doesn't,
            // particularly bookmarked URLs and quick-existence checks.
            return (try? URL(fileURLWithPath: statTarget).checkResourceIsReachable()) ?? false
        }
    )

    /// Resolved (OS-reported) volume names, keyed like the reachability
    /// cache. `URLResourceValues(forKeys: [.volumeNameKey])` is a disk hit —
    /// it was being paid PER RENDER via `displayLabel(forPath:)` in the
    /// catalog's Volume column. Names effectively never change while mounted,
    /// so the TTL is long; mount/unmount invalidation handles renames-on-
    /// remount. Value is `String?`: nil means "probe ran and failed"
    /// (offline volume) — callers fall back to the path-string heuristic.
    private static let volumeNameCache = SWRProbeCache<String?>(
        label: "Rick-Breen.VideoScan.volumeReachability.volumeName",
        ttl: 60.0,
        valuesEqual: { $0 == $1 },
        onChange: { _ in postReachabilityDidChange() },
        probe: { key in
            guard let vals = try? URL(fileURLWithPath: key).resourceValues(forKeys: [.volumeNameKey]),
                  let name = vals.volumeName, !name.isEmpty else { return nil }
            return name
        }
    )

    // MARK: - Kernel mount table (honest, disk-free defaults)

    /// Snapshot of currently mounted filesystem roots ("/", "/Volumes/X", …).
    /// Refreshed at first use and on every mount/unmount invalidation.
    /// `getmntinfo(MNT_NOWAIT)` reads the kernel's in-memory mount list —
    /// it does NOT statfs the filesystems, so it can never spin up a
    /// sleeping HDD or hang on a dead SMB mount. (C++ analogy: reading
    /// /proc/mounts, not touching the devices.)
    nonisolated(unsafe) private static var mountedRoots: Set<String> = currentMountedRoots()
    private static let mountedRootsLock = OSAllocatedUnfairLock()

    /// Serializes the raw `getmntinfo` call. `getmntinfo(3)` returns a pointer
    /// into a single libc-owned static buffer that it may `realloc` in place;
    /// it is NOT reentrant/thread-safe. The reachability probe queue is
    /// concurrent, so `/Volumes` probes can call `currentMountedRoots()` from
    /// several threads at once — without this lock they would race on that
    /// shared buffer (torn reads at best, use-after-free under a concurrent
    /// realloc at worst). The lock is held only across the microsecond
    /// in-kernel read + copy-out into a Swift `Set`, so it never blocks on I/O.
    private static let getmntinfoLock = OSAllocatedUnfairLock()

    /// Read the kernel mount table. Internal so tests can sanity-check it
    /// ("/" must always be present) without faking mounts.
    static func currentMountedRoots() -> Set<String> {
        getmntinfoLock.withLockUnchecked {
            var mntPtr: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mntPtr, MNT_NOWAIT)
            guard count > 0, let mntPtr else { return [] }
            var roots = Set<String>()
            for i in 0..<Int(count) {
                var fs = mntPtr[i]
                let mountPoint = withUnsafePointer(to: &fs.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }
                roots.insert(mountPoint)
            }
            // getmntinfo's buffer is reused static storage owned by libc — never
            // freed; the copy-out above completes before we drop the lock.
            return roots
        }
    }

    /// The honest no-cache-entry answer. Pure — unit-tested directly.
    /// For /Volumes keys the kernel mount table IS the truth for "is this
    /// volume mounted". Non-/Volumes keys (internal disk paths) default
    /// optimistic-true: their probes resolve in milliseconds and a wrong
    /// `true` for one frame matches the UI's attempt-and-fail behavior.
    static func defaultReachability(forKey key: String, mountedRoots: Set<String>) -> Bool {
        if key.hasPrefix("/Volumes/") {
            return mountedRoots.contains(key)
        }
        return true
    }

    /// Drop all cached entries and re-snapshot the kernel mount table.
    /// Call after volume mount/unmount notifications.
    static func invalidateCache() {
        let fresh = currentMountedRoots()
        mountedRootsLock.withLockUnchecked { mountedRoots = fresh }
        reachabilityCache.invalidateAll()
        volumeNameCache.invalidateAll()
    }

    /// Test seam: block until all in-flight background probes (reachability
    /// AND volume-name) have landed, so tests can assert post-refresh state
    /// deterministically.
    internal static func awaitPendingProbesForTesting() {
        reachabilityCache.awaitPendingProbes()
        volumeNameCache.awaitPendingProbes()
    }

    /// True if the volume containing `path` is currently mounted. For paths
    /// under `/Volumes/X/...` this answers "is /Volumes/X mounted right now?"
    /// — independent of whether the specific file exists. For internal paths
    /// (not under /Volumes) it falls back to a per-path existence check, which
    /// is the right answer when there's no separable "volume" to ask about.
    ///
    /// NEVER touches the disk on the caller's thread — see the
    /// stale-while-revalidate notes on `reachabilityCache`. Answers may be up
    /// to TTL+probe-time stale; an unknown /Volumes path is answered honestly
    /// from the kernel mount table (microseconds, no disk I/O).
    ///
    /// Note: if you need "does this specific file exist?", use
    /// `FileManager.default.fileExists(atPath:)` directly — that's a different
    /// question from this one.
    static func isReachable(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let key = cacheKey(forPath: path)
        let mounted = mountedRootsLock.withLockUnchecked { mountedRoots }
        return reachabilityCache.value(
            forKey: key,
            missDefault: defaultReachability(forKey: key, mountedRoots: mounted))
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
    ///
    /// Cached stale-while-revalidate (see `volumeNameCache`) — this used to
    /// hit the disk per render via `displayLabel`, which beachballed on
    /// sleeping HDDs exactly like `isReachable` did. Unknown or
    /// unresolvable volumes use the path heuristic until/unless the
    /// background probe produces an OS name.
    private static func resolvedVolumeName(forPath path: String) -> String {
        guard !path.isEmpty else { return "" }
        let key = cacheKey(forPath: path)
        let resolved = volumeNameCache.value(forKey: key, missDefault: nil)
        return resolved ?? volumeName(forPath: path)
    }
}
