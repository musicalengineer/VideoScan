// TestScratch.swift — a test's temp folders are removed when the test ends.
//
// The SAME file as VideoScanCore/Tests/VideoScanCoreTests/TestScratch.swift:
// the app's and Core's test targets cannot share test-only code, and Core's
// library must not link Testing. Change both together.
//
// Rick 2026-11-23: "it is lazy programming to take disk space then not free
// it" (DECISIONS 2026-11-23: disk is a resource — allocate, then free). Test
// fixtures made folders under NSTemporaryDirectory() and never removed them:
// measured on the Ultra, ~190 runs of MediaRepairEngineTests alone had left
// 7.8 GB.
//
// The pattern, in two parts:
//   * `TestScratch.directory(named:)` makes `<root>/<name>` and records it in
//     the CURRENT TEST's scope.
//   * `.scratchCleanup` on a suite (or a test) gives every test case its own
//     scope and removes what was recorded when the case ends — pass, fail,
//     throw or cancel.
// <root> is TestHostScratch.testTempRoot: the runner's VIDEOSCAN_TEST_TMP
// when it sets one (the runner frees it after the run), else the user temp dir.
// A fixture helper calls `directory(named:)` instead of createDirectory; its
// callers never write cleanup code, and a helper that returns the folder to
// its caller is safe (the folder lives until the TEST ends, not the helper).
//
// Asked outside a scope, `directory(named:)` still makes the folder but
// records an Issue naming the suite to tag — a leak is a red test, not a
// silent one.
//
// ≈ C++: the trait is a scope guard the test framework wraps around each test
// body; the task-local is a thread_local pointer to that guard's list (but it
// follows the test's async work across threads, which thread_local would not).
//
// Worst-case memory: one URL per folder a test case makes, freed when the
// case ends.

import Foundation
import Testing
import VideoScanCore
import os

enum TestScratch {

    /// The folders made inside one test case.
    final class Scope: Sendable {
        private let urls = OSAllocatedUnfairLock(initialState: [URL]())

        func record(_ url: URL) { urls.withLock { $0.append(url) } }

        var recorded: [URL] { urls.withLock { $0 } }

        /// Remove every recorded folder that is a DIRECT child of the root:
        /// realpath(its parent) == realpath(root), exactly — a symlinked
        /// parent cannot match (Codex 2026-11-23 r2 #3: root/link/victim with
        /// link → outside removed the outside victim). Deleted, not trashed:
        /// test scratch is regenerable (DECISIONS 2026-11-23). Residual: a
        /// parent swapped between this check and removeItem — a guard against
        /// test bugs, not an adversary; the runner's rmtree is the backstop.
        func removeAll() {
            let all = urls.withLock { list -> [URL] in
                let copy = list
                list.removeAll()
                return copy
            }
            guard let root = TestHostScratch.realPath(TestScratch.tempRoot) else { return }
            for url in all {
                let name = url.lastPathComponent
                guard !name.isEmpty, name != ".", name != "..", name != "/",
                      let parent = TestHostScratch.realPath(url.deletingLastPathComponent()),
                      parent == root else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The running test case's scope (nil outside `.scratchCleanup`).
    /// `@TaskLocal` ≈ a thread_local that child tasks inherit.
    @TaskLocal static var current: Scope?

    /// The runner's VIDEOSCAN_TEST_TMP when set, else the user temp dir
    /// (TestHostScratch.testTempRoot — one definition for both kinds of scratch).
    static var tempRoot: URL { TestHostScratch.testTempRoot }

    /// A name `directory(named:)` refuses: not one plain path component.
    struct NotAFlatName: Error, CustomStringConvertible {
        let name: String
        var description: String { "TestScratch: \(name) is not a direct child of the root (one component, no '/')" }
    }

    /// Make `<root>/<name>` — a DIRECT child of the root, so the scope's
    /// removal can prove what it removes — and record it for removal when the
    /// current test case ends. Work a test leaves running (an abandoned
    /// supervisor that rewrites holds.json — JobScheduleTests) can re-create
    /// it afterwards; under the runner the sealed tmp is deleted after the run.
    @discardableResult
    static func directory(named name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            Issue.record("\(NotAFlatName(name: name))")
            throw NotAFlatName(name: name)
        }
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if let scope = current {
            scope.record(url)
        } else {
            Issue.record("TestScratch: \(name) was made outside a .scratchCleanup scope and will be left on disk — tag the suite @Suite(.scratchCleanup)")
        }
        return url
    }

    /// `<root>/<prefix><UUID>` — the usual unique-per-call shape.
    static func unique(_ prefix: String) throws -> URL {
        try directory(named: prefix + UUID().uuidString)
    }
}

/// `@Suite(.scratchCleanup)` / `@Test(.scratchCleanup)`: every test case runs
/// in its own `TestScratch.Scope`, emptied when the case ends.
struct ScratchCleanupTrait: SuiteTrait, TestTrait, TestScoping {
    /// Applied to a suite, it reaches every test inside (nested suites too).
    var isRecursive: Bool { true }

    /// One scope per test CASE (each argument of a parameterized test), none
    /// for a suite as a whole.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> ScratchCleanupTrait? {
        testCase == nil ? nil : self
    }

    /// `@concurrent` spells out the protocol's exact signature: the app's
    /// test target defaults async functions to the caller's actor
    /// (NonisolatedNonsendingByDefault), Testing's requirement does not.
    @concurrent
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let scope = TestScratch.Scope()
        defer { scope.removeAll() }
        try await TestScratch.$current.withValue(scope) { try await function() }
    }
}

extension Trait where Self == ScratchCleanupTrait {
    static var scratchCleanup: Self { ScratchCleanupTrait() }
}
