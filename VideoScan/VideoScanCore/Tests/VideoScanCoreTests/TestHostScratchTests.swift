// TestHostScratchTests.swift — a test process frees the temp folders it took
// (Rick 2026-11-23; DECISIONS 2026-11-23). Two halves:
//   * TestHostScratch — the per-PROCESS folders (`VideoScan-test-appsupport-
//     <pid>`, …) are recorded and removed by one exit handler; the removal
//     never reaches outside the temp dir;
//   * TestScratch — a per-TEST fixture folder (BackgroundFixtures.scratch,
//     2,358 `BackgroundTests-era-*` left on the Ultra) is gone when its test
//     case's scope ends.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Test temp folders are freed — per process and per test (Core)")
struct TestHostScratchTests {

    /// Under the process's test temp root (VIDEOSCAN_TEST_TMP when the runner
    /// sets it, else the user temp dir).
    private static func tmp(_ name: String) -> URL {
        TestHostScratch.testTempRoot.appendingPathComponent(name, isDirectory: true)
    }

    @Test("a registry removes what it recorded inside the temp dir, and only that")
    func registryRemovesOnlyInsideTheTempDir() throws {
        let registry = TestHostScratch.Registry()
        let inside = Self.tmp("TestHostScratchTests-\(UUID().uuidString)")
        let nested = Self.tmp("TestHostScratchTests-sub-\(UUID().uuidString)").appendingPathComponent("x-123", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: inside)
            try? FileManager.default.removeItem(at: nested.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(registry.register(inside))
        #expect(registry.register(nested))
        #expect(!registry.register(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)), "home is never removable")
        #expect(!registry.register(URL(fileURLWithPath: "/", isDirectory: true)))
        #expect(!registry.register(TestHostScratch.testTempRoot), "the root itself is not")
        #expect(!registry.register(Self.tmp("..")), "nor its parent")
        #expect(!registry.register(Self.tmp("a/../../escape")))
        #expect(registry.isRegistered(inside))

        #expect(registry.removeAll() == 2)
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: NSHomeDirectory()))
        #expect(!registry.isRegistered(inside), "drained")
        #expect(registry.removeAll() == 0, "a second drain removes nothing")
    }

    @Test("the /private spelling of the temp dir is the same place")
    func privateSpellingIsInside() {
        let registry = TestHostScratch.Registry()
        let root = TestHostScratch.testTempRoot.path
        let spelled = root.hasPrefix("/private/") ? String(root.dropFirst("/private".count)) : "/private" + root
        #expect(registry.register(URL(fileURLWithPath: spelled).appendingPathComponent("y-1")))
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

    // Codex 2026-11-23 #352 P1-2: the inside-the-root check compared spellings; S/link/victim with link → outside
    // removed the outside victim. Removal now compares RESOLVED paths.
    @Test("a registered path through a symlinked parent is never removed")
    func symlinkedParentIsRefusedAtRemoval() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("THS-symlink-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("victim"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let registry = TestHostScratch.Registry(root: root)
        _ = registry.register(root.appendingPathComponent("link/victim", isDirectory: true))
        _ = registry.removeAll()
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("victim").path),
                "a folder outside the root was removed through a symlinked parent")
    }

    // Codex 2026-11-23 #352 P1-3: what enters an auto-emptied test trash must itself be scratch.
    @Test("isScratch: inside the test temp root or the temp dir, resolved; never home, never through a symlink out")
    func isScratchIsResolvedAndBounded() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("THS-isScratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("a"), withIntermediateDirectories: true)
        #expect(TestHostScratch.isScratch(base.appendingPathComponent("a")))
        #expect(!TestHostScratch.isScratch(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")))
        #expect(!TestHostScratch.isScratch(URL(fileURLWithPath: "/")))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("out"),
                                                   withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        #expect(!TestHostScratch.isScratch(base.appendingPathComponent("out/Movies")), "a symlink out of temp is not scratch")
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

    @Test("under a test process, a per-process folder is recorded for removal at exit")
    func perProcessIsRecordedUnderATestProcess() {
        #expect(TestHostDetection.isTestHost)
        let url = TestHostScratch.perProcess("TestHostScratchTests-probe")
        #expect(url.lastPathComponent == "TestHostScratchTests-probe-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(TestHostScratch.shared.isRegistered(url))
    }

    @Test("Core's own per-process test folders are recorded for removal at exit")
    func coreStoresRecordTheirFolders() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appSupport = TestHostDetection.sandboxedApplicationSupportRoot(for: "TestHostScratchTests")
        _ = FamilyGraphCompiledStore.production
        _ = PreviewDiskCache.productionRootURL
        #expect(appSupport.map { TestHostScratch.shared.isRegistered($0) } == true)
        #expect(TestHostScratch.shared.isRegistered(Self.tmp("VideoScan-test-compiled-\(pid)")))
        #expect(TestHostScratch.shared.isRegistered(Self.tmp("VideoScanTests-\(pid)")))
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
