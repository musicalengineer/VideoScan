// TestHostScratchTests.swift — test scratch lives where it is freed (Rick
// 2026-11-23; DECISIONS 2026-11-23). Two halves:
//   * TestHostScratch — the per-PROCESS folders (`VideoScan-test-appsupport-
//     <pid>`, …) lie under the test temp root, which the RUNNER deletes; a test
//     process deletes none of them. `isScratch` resolves symlinks before `..`;
//   * TestScratch — a per-TEST fixture folder (BackgroundFixtures.scratch,
//     2,358 `BackgroundTests-era-*` left on the Ultra) is gone when its test
//     case's scope ends.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Test temp folders are freed — per process and per test (Core)")
struct TestHostScratchTests {

    /// Rick's REAL home from the account database — under the runner NSHomeDirectory() is the sealed home
    /// (HOME = CFFIXED_USER_HOME), and "the real home is never scratch" must test the real one.
    static var realHome: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return URL(fileURLWithPath: "/nonexistent") }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    /// Under the process's test temp root (VIDEOSCAN_TEST_TMP when the runner
    /// sets it, else the user temp dir).
    private static func tmp(_ name: String) -> URL {
        TestHostScratch.testTempRoot.appendingPathComponent(name, isDirectory: true)
    }

    @Test("VIDEOSCAN_TEST_TMP names the root in a test process; unset, relative or in production it is the fallback")
    func rootHonorsTheRunnersVariable() {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let key = TestHostScratch.rootEnvironmentKey
        #expect(key == "VIDEOSCAN_TEST_TMP")
        #expect(TestHostScratch.root(environment: [key: "/x/home/tmp"], isTestProcess: true, fallback: fallback,
                                     isMarked: { _ in true }).path == "/x/home/tmp")
        #expect(TestHostScratch.root(environment: [:], isTestProcess: true, fallback: fallback) == fallback, "unset")
        #expect(TestHostScratch.root(environment: [key: ""], isTestProcess: true, fallback: fallback) == fallback, "empty")
        #expect(TestHostScratch.root(environment: [key: "rel/tmp"], isTestProcess: true, fallback: fallback) == fallback,
                "only an absolute path counts")
        #expect(TestHostScratch.root(environment: [key: "/x/home/tmp"], isTestProcess: false, fallback: fallback) == fallback,
                "production ignores it")
    }

    // Codex 2026-11-23 #352 P1-1: any absolute VIDEOSCAN_TEST_TMP was trusted as a deletion root (/, /Users, a real
    // Application Support). A root must PROVE it is the runner's scratch: its marker file.
    @Test("an env root without the runner's marker — or '/' — is never trusted; the fallback is used")
    func rootRequiresTheRunnersMarker() throws {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let key = TestHostScratch.rootEnvironmentKey
        let unmarked = fallback.appendingPathComponent("THS-unmarked-\(UUID().uuidString)", isDirectory: true)
        let marked = fallback.appendingPathComponent("THS-marked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unmarked); try? FileManager.default.removeItem(at: marked) }
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        try Data().write(to: marked.appendingPathComponent(TestHostScratch.rootMarkerName))
        #expect(TestHostScratch.root(environment: [key: unmarked.path], isTestProcess: true, fallback: fallback) == fallback)
        #expect(TestHostScratch.root(environment: [key: NSHomeDirectory()], isTestProcess: true, fallback: fallback) == fallback)
        #expect(TestHostScratch.root(environment: [key: "/"], isTestProcess: true, fallback: fallback,
                                     isMarked: { _ in true }) == fallback, "'/' never, even marked")
        #expect(TestHostScratch.root(environment: [key: marked.path], isTestProcess: true, fallback: fallback).path
                == marked.standardizedFileURL.path)
    }

    // Codex 2026-11-23 #352 P1-3: what enters an auto-emptied test trash must itself be scratch.
    @Test("isScratch: inside the test temp root or the temp dir, resolved; never home, never through a symlink out")
    func isScratchIsResolvedAndBounded() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("THS-isScratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("a"), withIntermediateDirectories: true)
        #expect(TestHostScratch.isScratch(base.appendingPathComponent("a")))
        #expect(!TestHostScratch.isScratch(Self.realHome.appendingPathComponent("Movies")))
        #expect(!TestHostScratch.isScratch(URL(fileURLWithPath: "/")))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("out"),
                                                   withDestinationURL: Self.realHome)
        #expect(!TestHostScratch.isScratch(base.appendingPathComponent("out/Movies")), "a symlink out of temp is not scratch")
    }

    // Codex 2026-11-23 round 2 #2: isScratch folded `..` BEFORE resolving symlinks. With S/link → O/child,
    // S/link/../victim.mov names O/victim.mov, but standardizing first made it S/victim.mov — "scratch".
    @Test("isScratch resolves symlinks before `..`: S/link/../victim.mov (really O/victim.mov) is not scratch")
    func isScratchResolvesSymlinksBeforeDotDot() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("THS-dotdot-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)          // the synthetic scratch root
        let s = root.appendingPathComponent("S", isDirectory: true)
        let o = base.appendingPathComponent("O", isDirectory: true)                // OUTSIDE the root
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: o.appendingPathComponent("child"), withIntermediateDirectories: true)
        try Data([1]).write(to: o.appendingPathComponent("victim.mov"))
        try FileManager.default.createSymbolicLink(at: s.appendingPathComponent("link"),
                                                   withDestinationURL: o.appendingPathComponent("child"))
        let source = URL(fileURLWithPath: s.path + "/link/../victim.mov")
        #expect(!TestHostScratch.isScratch(source, roots: [root]), "\(source.path) is \(o.path)/victim.mov")
        #expect(TestHostScratch.isScratch(s.appendingPathComponent("plain.mov"), roots: [root]), "a plain child still is")
        #expect(!TestHostScratch.isScratch(URL(fileURLWithPath: s.path + "/missing/../x.mov"), roots: [root]),
                "`..` in the part that does not exist is refused")
        #expect(!TestHostScratch.isScratch(root, roots: [root]), "the root itself is not scratch")
    }

    // Codex 2026-11-23 round 2 #3: a TestScratch scope removed what it recorded after a LEXICAL inside-the-root
    // check, so root/link/victim with link → outside removed the outside victim.
    @Test("a scope never removes through a symlinked parent (only direct children of the root)")
    func scopeNeverRemovesThroughASymlink() throws {
        let root = TestScratch.tempRoot
        let outside = root.appendingPathComponent("THS-outside-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("THS-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("victim"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = TestScratch.Scope()
        scope.record(link.appendingPathComponent("victim", isDirectory: true))
        scope.removeAll()
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("victim").path),
                "removed through a symlinked parent")
    }

    @Test("this process's root follows its own environment, and is a directory")
    func thisProcessRootMatchesItsEnvironment() {
        let env = ProcessInfo.processInfo.environment[TestHostScratch.rootEnvironmentKey] ?? ""
        let marked = env.hasPrefix("/") && env != "/"
            && FileManager.default.fileExists(atPath: (env as NSString).appendingPathComponent(TestHostScratch.rootMarkerName))
        let expected = marked
            ? URL(fileURLWithPath: env, isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(TestHostScratch.testTempRoot == expected)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: TestHostScratch.testTempRoot.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(TestHostScratch.perProcess("TestHostScratchTests-root").deletingLastPathComponent().path
                == TestHostScratch.testTempRoot.path)
    }

    // Codex 2026-11-23 rounds 1–2: deleting by path at exit was bypassable, so test processes no longer delete
    // per-process folders at all — they live under the test temp root, which the runner deletes.
    @Test("perProcess only names <testTempRoot>/<name>-<pid>: it creates and deletes nothing")
    func perProcessDeletesNothing() throws {
        let name = "TestHostScratchTests-probe-\(UUID().uuidString)"
        let url = TestHostScratch.perProcess(name)
        #expect(url.lastPathComponent == "\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(url.deletingLastPathComponent().path == TestHostScratch.testTempRoot.path)
        #expect(!FileManager.default.fileExists(atPath: url.path), "not created")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = TestHostScratch.perProcess(name)
        #expect(FileManager.default.fileExists(atPath: url.path), "an existing folder is left alone")
    }

    @Test("every Core per-process test folder lies under the test temp root (so the runner frees it)")
    func everyCorePerProcessFolderIsUnderTheRoot() throws {
        let root = TestHostScratch.testTempRoot.path
        let appSupport = try #require(TestHostDetection.sandboxedApplicationSupportRoot(for: "TestHostScratchTests"))
        let folders = [appSupport, FamilyGraphCompiledStore.production.root,
                       PreviewDiskCache.productionRootURL]
        for url in folders {
            #expect(url.path.hasPrefix(root + "/"), "\(url.path) is not under \(root)")
        }
    }

    @Test("GUARD: a BackgroundFixtures scratch folder is gone when its test's scope ends (before/after listing)")
    func backgroundScratchIsGoneWhenTheTestEnds() throws {
        let prefix = "BackgroundTests-leakguard-"
        func listing() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: TestHostScratch.testTempRoot.path)) ?? [])
                .filter { $0.hasPrefix(prefix) })
        }
        let before = listing()
        let scope = TestScratch.Scope()
        let dir = try TestScratch.$current.withValue(scope) { () throws -> URL in
            let made = try BackgroundFixtures.scratch("leakguard")
            try Data(repeating: 1, count: 1024).write(to: made.appendingPathComponent("state.json"))
            return made
        }
        defer { try? FileManager.default.removeItem(at: dir) }   // the guard must not leak when red
        scope.removeAll()
        #expect(!FileManager.default.fileExists(atPath: dir.path), "left behind: \(dir.path)")
        #expect(listing().subtracting(before).isEmpty)
    }
}
