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
    public static let testTempRoot: URL = {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = root(environment: ProcessInfo.processInfo.environment,
                       isTestProcess: TestHostDetection.isTestHost, fallback: fallback)
        if url != fallback {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }()

    /// `<testTempRoot>/<name>-<pid>` — the per-process folder for `name` (which may contain a subfolder, e.g.
    /// "VideoScan-tests/ledger"). Not created, recorded or removed here: the runner frees the root.
    public static func perProcess(_ name: String) -> URL {
        testTempRoot.appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
}
