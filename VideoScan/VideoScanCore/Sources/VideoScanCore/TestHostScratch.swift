// TestHostScratch.swift
//
// WHERE a test process's scratch lives — never who deletes it (Rick 2026-11-23:
// "it is lazy programming to take disk space then not free it"; DECISIONS
// 2026-11-23, disk is a resource: allocate, then free).
//
// Under a test host, two dozen stores redirect their real root to a folder
// named for the process — `<root>/VideoScanTestLogs-<pid>`,
// `<root>/VideoScan-tests/ledger-<pid>`, … — so parallel hosts never share
// one. `perProcess(name)` is that one spelling: `<testTempRoot>/<name>-<pid>`.
//
// THE ROOT. Foundation on macOS ignores $TMPDIR (measured 2026-11-23), so the
// runner sets `VIDEOSCAN_TEST_TMP` = <sealed home>/tmp and marks it with
// `.videoscan-test-tmp` (scripts/xctest_shards.py, core_lane.py,
// sealed_home.py). `testTempRoot` is that directory when the variable names a
// marked absolute path (never "/") in a test process, else the user temp dir.
//
// WHO FREES IT. Under the runner, the sealed tmp: the RUNNER reports what is
// left there by prefix and deletes the whole sealed home after the run
// (shutil.rmtree, which resists symlink attacks). Run by hand (Xcode ⌘U), the
// folders land in the user temp dir, which macOS clears. NO deletion happens
// inside a test process except TestScratch's per-test scope (a direct child
// of the root, resolved). An earlier version removed per-process folders from
// an atexit handler, guarded by path checks; Codex (2026-11-23, rounds 1–2)
// showed those checks bypassable (a root swapped for a symlink after init,
// `..` folded before symlinks resolved, check/use races) — deleting by path
// at exit was the design flaw, so it is gone.
//
// `isScratch` remains: under a test host the test trashes (MediaTrash, the POI
// trash) live in the root the runner deletes, so nothing that is not scratch
// may be moved into them. Residual (Codex r2 #5): a check and the move that
// follows are two system calls, so a process rewriting the tree between them
// could still redirect the move. These guards stop test BUGS, not an
// adversary racing the test; the deletion that matters is the runner's rmtree.
//
// Production is untouched: outside a test process the variable is ignored and
// `perProcess` returns the same URL as before.
//
// Memory: none held (no registry).

import Foundation

public enum TestHostScratch {

    /// The environment variable a test runner sets to give test processes
    /// their own temp root.
    public static let rootEnvironmentKey = "VIDEOSCAN_TEST_TMP"

    /// The file a runner puts in the root it hands over (scripts/sealed_home.py). A root WITHOUT it is never
    /// taken as the test temp root (Codex 2026-11-23 #352 P1-1: an arbitrary absolute VIDEOSCAN_TEST_TMP — "/",
    /// /Users, a real Application Support — was accepted).
    public static let rootMarkerName = ".videoscan-test-tmp"

    /// Pure: the root `environment` names for a process that is (or is not) a test, else `fallback`. Only an
    /// absolute path other than "/" that carries the runner's marker (`isMarked`) counts.
    public static func root(environment: [String: String], isTestProcess: Bool, fallback: URL,
                            isMarked: (URL) -> Bool = TestHostScratch.carriesMarker) -> URL {
        guard isTestProcess,
              let value = environment[rootEnvironmentKey], value.hasPrefix("/")
        else { return fallback }
        let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        guard url.path != "/", isMarked(url) else { return fallback }
        return url
    }

    public static func carriesMarker(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rootMarkerName).path)
    }

    /// True when `url` is test scratch: with every symlink resolved, strictly inside this process's test temp root
    /// or the user temp dir. Under a test host nothing else may enter a test trash (it lives in what the runner
    /// deletes).
    public static func isScratch(_ url: URL) -> Bool {
        isScratch(url, roots: [testTempRoot, URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
    }

    /// `isScratch` against explicit roots (a test passes a synthetic one). Symlinks are resolved BEFORE any `..`
    /// is interpreted (Codex 2026-11-23 r2 #2: folding `..` first turned S/link/../victim — really O/victim — into
    /// S/victim): the raw path is never standardized; the deepest EXISTING ancestor is realpath'd (the kernel
    /// resolves `..` after the symlinks before it), and a non-existent remainder holding `.` or `..` is refused.
    public static func isScratch(_ url: URL, roots: [URL]) -> Bool {
        guard let resolved = resolvedPath(rawPath: url.path) else { return false }
        return roots.contains { root in
            guard let base = resolvedPath(rawPath: root.path), base != "/" else { return false }
            return resolved.hasPrefix(base + "/")
        }
    }

    /// realpath() of the deepest existing ancestor of `rawPath`, with the non-existent remainder appended; nil when
    /// that remainder contains `.` or `..` (it cannot be resolved honestly) or the path is not absolute.
    static func resolvedPath(rawPath: String) -> String? {
        guard rawPath.hasPrefix("/") else { return nil }
        var existing = rawPath
        var tail: [String] = []
        while existing != "/" && !FileManager.default.fileExists(atPath: existing) {
            let name = (existing as NSString).lastPathComponent
            if name == "." || name == ".." { return nil }
            if !name.isEmpty { tail.insert(name, at: 0) }
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realPath(existing) else { return nil }
        return tail.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// realpath() of an existing path; nil if it does not exist.
    public static func realPath(_ url: URL) -> String? { realPath(url.path) }

    static func realPath(_ path: String) -> String? {
        // realpath(3) with a nil buffer mallocs the result (≈ C++: a char* we own and must free()).
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The temp root for test scratch in THIS process (computed once; created
    /// when it is the runner's and missing).
    public static var testTempRoot: URL { rootAndPin.root }

    /// The test temp root as a path guard may trust it (Codex 2026-11-24, cycle #361 P1): the validated
    /// directory's IDENTITY, taken once, not its URL. A guard that re-resolved the root's URL on every call
    /// admitted every path once the root was replaced by a symlink to `/` (or the home, or the archive). So:
    ///   * `resolvedPath` is the realpath taken when the marker was checked — callers compare a candidate's
    ///     canonical path against this STRING and never resolve the root again;
    ///   * `device`/`inode` are the directory's (st_dev, st_ino) at that moment — `isIntact` re-lstat()s
    ///     `resolvedPath` and refuses unless it is still that same real directory (not a symlink, not a
    ///     replacement folder);
    ///   * the root must sit strictly inside a scratch parent (`defaultAllowedParents`: the per-user temp dir,
    ///     /private/tmp, the real ~/Library/Caches) — so `/`, a home, the real Library or App Support, any
    ///     /Volumes path (the archive) is never pinned, marker or not.
    /// Residual: the check and the caller's later system call are two calls; a guard against test bugs, not
    /// an adversary racing the test. ≈ C++: keep the (dev, ino) of the file you validated, not its pathname.
    public struct PinnedRoot: Sendable, Equatable {
        public let resolvedPath: String
        public let device: UInt64
        public let inode: UInt64

        /// nil unless `url` resolves to a real directory carrying the runner's marker, inside an allowed parent.
        public static func pin(_ url: URL, allowedParents: [String] = defaultAllowedParents()) -> PinnedRoot? {
            guard let resolved = TestHostScratch.realPath(url), resolved != "/",
                  isAllowedLocation(resolved, allowedParents: allowedParents),
                  let first = identity(resolved) else { return nil }
            var st = stat()
            let marker = (resolved as NSString).appendingPathComponent(rootMarkerName)
            // The same directory before and after the marker check.
            guard lstat(marker, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  let second = identity(resolved), second == first else { return nil }
            return PinnedRoot(resolvedPath: resolved, device: first.0, inode: first.1)
        }

        /// `resolvedPath` still names the directory that was pinned: lstat (a symlink fails), a directory,
        /// same (dev, ino).
        public var isIntact: Bool {
            guard let now = PinnedRoot.identity(resolvedPath) else { return false }
            return now == (device, inode)
        }

        /// `canonical` (already realpath'd by the caller) is the root or below it, and the root is intact.
        public func contains(canonicalPath canonical: String) -> Bool {
            guard isIntact else { return false }
            return canonical == resolvedPath || canonical.hasPrefix(resolvedPath + "/")
        }

        /// Pure: `resolved` lies STRICTLY inside one of `allowedParents` (each compared slash-delimited, so
        /// /private/tmpX is not inside /private/tmp, and the parent itself is not allowed).
        public static func isAllowedLocation(_ resolved: String, allowedParents: [String]) -> Bool {
            allowedParents.contains { parent in
                let p = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
                return !p.isEmpty && p != "/" && resolved.hasPrefix(p + "/")
            }
        }

        /// Where a runner may put the test temp root: the per-user temp dir (sealed_home.py, core_lane.py
        /// mkdtemp), /private/tmp, and the REAL account's ~/Library/Caches (xctest_shards.py's run folders) —
        /// each realpath'd. The real home comes from the password database, not $HOME (a sealed run moves HOME).
        public static func defaultAllowedParents() -> [String] {
            var parents = [NSTemporaryDirectory(), "/private/tmp"]
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                parents.append((String(cString: dir) as NSString).appendingPathComponent("Library/Caches"))
            }
            return parents.compactMap { TestHostScratch.realPath($0) }
        }

        /// (st_dev, st_ino) of `path` when lstat() finds a real directory there (never through a final symlink).
        static func identity(_ path: String) -> (UInt64, UInt64)? {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
        }
    }

    /// The pin of `testTempRoot`, taken together with it (nil when the root is the user temp dir fallback, or
    /// cannot be pinned — then a guard admits only the user temp dir).
    public static var testTempRootPin: PinnedRoot? { rootAndPin.pin }

    private static let rootAndPin: (root: URL, pin: PinnedRoot?) = {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = root(environment: ProcessInfo.processInfo.environment,
                       isTestProcess: TestHostDetection.isTestHost, fallback: fallback)
        guard url != fallback else { return (url, nil) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, PinnedRoot.pin(url))
    }()

    /// `<testTempRoot>/<name>-<pid>` — the per-process folder for `name` (which may contain a subfolder, e.g.
    /// "VideoScan-tests/ledger"). Not created, recorded or removed here: the runner frees the root.
    public static func perProcess(_ name: String) -> URL {
        testTempRoot.appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
}
