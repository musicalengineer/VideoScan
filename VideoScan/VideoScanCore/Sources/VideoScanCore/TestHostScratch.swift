// TestHostScratch.swift
//
// THE one owner of a test process's PER-PROCESS temp folders (Rick
// 2026-11-23: "it is lazy programming to take disk space then not free it";
// DECISIONS 2026-11-23, disk is a resource: allocate, then free).
//
// Under a test host, two dozen stores redirect their real root to a folder
// named for the process — `<tmp>/VideoScanTestLogs-<pid>`,
// `<tmp>/VideoScan-tests/ledger-<pid>`, … — so parallel hosts never share
// one. Nothing ever removed them: measured on the Ultra 2026-11-23, ~970
// host launches had left ~970 of each (VideoScan-tests alone 6.6 GB).
//
// The fix keeps the folders per process (parallel shards still never collide)
// and has the process remove its own at exit: whoever names a per-process
// folder asks HERE, which records it; one `atexit` handler, installed on the
// first registration, removes every recorded folder when the process exits
// normally (XCTest and swift test both end the run with exit()). Why not the
// runner's TMPDIR: xcodebuild launches the test host through testmanagerd,
// which does not pass the runner's environment on, so the host's temp dir is
// the user temp dir whatever the runner sets (that is where the leaks were).
// A host that crashes or is SIGKILLed still leaves its folders; that is the
// weekly prune's job (BACKLOG 2026-11-23 item 3), not this file's.
//
// THE ROOT. Foundation on macOS ignores $TMPDIR (measured 2026-11-23:
// NSTemporaryDirectory() and FileManager.temporaryDirectory both stay
// /var/folders/…/T with TMPDIR=/x), so a runner cannot move a test's temp
// folders with TMPDIR. It sets `VIDEOSCAN_TEST_TMP` instead (scripts/
// xctest_shards.py, core_lane.py: <sealed home>/tmp, reported by prefix and
// freed after the run). `testTempRoot` is that directory when the variable
// names an absolute path in a test process, else the user temp dir. Every
// per-process folder here and every per-test TestScratch folder lives under
// it, so the runner's root is the backstop for whatever a crash leaves.
//
// Production is untouched: outside a test process the variable is ignored,
// `perProcess` returns the same URL as before but records nothing and installs
// no handler.
//
// ≈ C++: a process-wide registry of temp paths plus one std::atexit callback
// that walks it — RAII for things whose lifetime is the whole process.
//
// Worst-case memory: one URL per distinct registered folder (~25 per
// process), held until exit.

import Foundation
import os

public enum TestHostScratch {

    /// The environment variable a test runner sets to give test processes
    /// their own temp root.
    public static let rootEnvironmentKey = "VIDEOSCAN_TEST_TMP"

    /// The file a runner puts in the root it hands over (scripts/sealed_home.py). A root WITHOUT it is never
    /// trusted for removal (Codex 2026-11-23 #352 P1-1: an arbitrary absolute VIDEOSCAN_TEST_TMP — "/", /Users,
    /// a real Application Support — was accepted as the deletion boundary).
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

    /// True when `url`, with every symlink resolved, lies strictly inside this process's test temp root or the
    /// user temp dir — i.e. it is test scratch. Under a test host, nothing else may enter a trash that is emptied
    /// at exit (Codex 2026-11-23 #352 P1-3: a real input moved there would be erased).
    public static func isScratch(_ url: URL) -> Bool {
        let resolved = resolvedPath(url)
        return [testTempRoot, URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)].contains { root in
            let base = resolvedPath(root)
            return base != "/" && resolved.hasPrefix(base + "/")
        }
    }

    /// The path with every symlink in its existing ancestors resolved (realpath of the deepest existing
    /// ancestor, then the rest appended), spelled without the /private prefix.
    static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(existing.path, &buf) != nil ? String(cString: buf) : existing.path
        let joined = tail.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
        return Registry.canonical(joined)
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

    /// A set of folders to remove, and the removal. An instance so a test can
    /// exercise the removal on its own folders without touching the live
    /// process's (the shared one is only ever drained by the exit handler).
    public final class Registry: Sendable {
        private let paths = OSAllocatedUnfairLock(initialState: Set<String>())
        /// The only tree a registry will remove from: the temp dir it was
        /// made with (`testTempRoot` by default).
        public let root: URL

        public init(root: URL = TestHostScratch.testTempRoot) {
            self.root = root.standardizedFileURL
        }

        /// Record `url` for removal. Refused (false) unless it lies strictly
        /// inside `root` — a registry never removes anything outside the temp
        /// dir, whatever a caller passes.
        @discardableResult
        public func register(_ url: URL) -> Bool {
            guard Self.isStrictlyInside(url, root) else { return false }
            paths.withLock { _ = $0.insert(url.standardizedFileURL.path) }
            return true
        }

        public func isRegistered(_ url: URL) -> Bool {
            paths.withLock { $0.contains(url.standardizedFileURL.path) }
        }

        /// Remove every registered folder that exists; returns how many were
        /// removed. Deleted, not trashed: test scratch is regenerable
        /// (DECISIONS 2026-11-23). The inside-root check is repeated here, at
        /// the moment of removal.
        @discardableResult
        public func removeAll() -> Int {
            let all = paths.withLock { set -> Set<String> in
                let copy = set
                set.removeAll()
                return copy
            }
            var removed = 0
            for path in all {
                let url = URL(fileURLWithPath: path)
                // At the moment of removal: the spelling AND the resolved path must be inside the root — a
                // symlinked parent (root/link → elsewhere) resolves outside and is refused (Codex 2026-11-23
                // #352 P1-2: S/link/victim removed the outside victim). A symlink LEAF is removed as a link.
                guard Self.isStrictlyInside(url, root), Self.resolvesInside(url, root),
                      FileManager.default.fileExists(atPath: path) else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
            return removed
        }

        static func isStrictlyInside(_ url: URL, _ root: URL) -> Bool {
            // Resolve the parent, not the leaf: the leaf may not exist yet,
            // and /var → /private/var must match on both sides.
            let leaf = url.standardizedFileURL     // ".." and "." folded away
            let name = leaf.lastPathComponent
            guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
            // /var is a symlink to /private/var and Foundation spells the temp
            // dir either way; the leaf may not exist yet, so compare spellings
            // rather than resolve.
            let parent = canonical(leaf.deletingLastPathComponent().path)
            let base = canonical(root.path)
            return parent == base || parent.hasPrefix(base + "/")
        }

        /// The leaf's PARENT, every symlink resolved, lies inside the resolved root.
        static func resolvesInside(_ url: URL, _ root: URL) -> Bool {
            let parent = TestHostScratch.resolvedPath(url.standardizedFileURL.deletingLastPathComponent())
            let base = TestHostScratch.resolvedPath(root)
            return base != "/" && (parent == base || parent.hasPrefix(base + "/"))
        }

        static func canonical(_ path: String) -> String {
            var p = path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
        }
    }

    /// The process's registry, drained by the exit handler.
    public static let shared = Registry()

    /// `<testTempRoot>/<name>-<pid>` — the per-process folder for `name`
    /// (which may contain a subfolder, e.g. "VideoScan-tests/ledger"). Not
    /// created here. Under a test process it is recorded for removal at exit.
    public static func perProcess(_ name: String) -> URL {
        let url = testTempRoot
            .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeAtExit(url)
        return url
    }

    /// Record a folder a test process made outside `perProcess`'s naming
    /// (a sibling such as `<store>-backups`) for removal at exit. A no-op
    /// outside a test process.
    public static func removeAtExit(_ url: URL) {
        guard TestHostDetection.isTestHost else { return }
        guard shared.register(url) else { return }
        installExitHandlerOnce()
    }

    /// `static let` initialisers run exactly once, thread-safely (≈ a C++
    /// function-local static), so `atexit` is called once per process.
    private static let exitHandler: Void = {
        // A C function pointer: the closure captures nothing (≈ a plain
        // `extern "C" void f()` handed to std::atexit).
        atexit { _ = TestHostScratch.shared.removeAll() }
    }()

    private static func installExitHandlerOnce() { _ = exitHandler }
}
