// FamilyTreeReadOnlyClosing5Tests.swift
// Codex cycle #199 (BLOCK, 1 × P1): Get Family Tree's scratch path was keyed
// by pid + output basename, so two pulls with different chosen destinations
// shared it — a forgotten pull A could finish and be published as pull B's
// export. Regression (Codex's), seen RED before the fix: two held runs A and
// B; release A → B still waiting, its output absent; release B → B's bytes.
// 2026-11-24: the same defect on Refresh from FamilySearch (second test).

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

private struct HeldScriptRunner: FamilySearchPullLauncher {
    let environment: [String: String]
    let workingDirectory: URL
    func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [url.path]
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        stdin.fileHandleForWriting.write(Data("\n".utf8))
    }
}

@Suite("Family Tree read-only — closing #199 (one scratch per launch)", .serialized)
@MainActor
struct FamilyTreeReadOnlyClosing5Tests {

    @Test func twoPullsNeverShareScratchAndBPublishesOnlyItsOwnBytes() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let fm = FileManager.default
        let bin = fx.root.appendingPathComponent("bin", isDirectory: true)
        let home = fx.root.appendingPathComponent("Home", isDirectory: true)
        for d in [bin, home] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        // One fixture tool: waits for $RELEASE, then copies $FIXTURE to its -o.
        let tool = bin.appendingPathComponent("getmyancestors")
        try """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        i=0
        while [ ! -f "$RELEASE" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
        cp "$FIXTURE" "$out"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        func pull(_ tag: String, people: Int) throws -> (FamilySearchPullCoordinator, URL, URL, Data) {
            let destDir = fx.root.appendingPathComponent("Chosen-\(tag)", isDirectory: true)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let fixture = fx.root.appendingPathComponent("answer-\(tag).ged")
            try ReadOnlyFixture.gedcom(people: people, generations: 2).write(to: fixture, atomically: true, encoding: .utf8)
            let release = fx.root.appendingPathComponent("release-\(tag)")
            let c = FamilySearchPullCoordinator(
                gedcomDirectory: fx.gedcomDirectory, defaultUsername: "rick@example.com",
                scriptURL: fx.familyTree.appendingPathComponent("get-family-tree-\(tag).command"),
                stagingDirectory: fx.familyTree.appendingPathComponent("staging-\(tag)"),
                locator: FamilySearchToolLocator(overridePath: tool.path),
                launcher: HeldScriptRunner(environment: ["RELEASE": release.path, "FIXTURE": fixture.path],
                                           workingDirectory: home),
                pollInterval: .milliseconds(30))
            c.compiledStore = { nil }
            // Same basename, different chosen destinations: the #199 shape.
            c.request.outputURL = destDir.appendingPathComponent("familysearch-tree.ged")
            return (c, release, c.request.outputURL, try Data(contentsOf: fixture))
        }
        let (a, releaseA, _, _) = try pull("A", people: 6)
        let (b, releaseB, outB, bytesB) = try pull("B", people: 9)
        a.launch()
        b.launch()
        guard case .waiting = a.phase, case .waiting = b.phase else {
            Issue.record("not waiting: \(a.phase) / \(b.phase)"); return
        }
        try await Task.sleep(for: .milliseconds(300))

        // A finishes first (the forgotten pull).
        try Data().write(to: releaseA)
        try await Task.sleep(for: .milliseconds(1_000))
        #expect({ if case .waiting = b.phase { return true }; return false }(), "B left waiting on A's output: \(b.phase)")
        #expect(!fm.fileExists(atPath: outB.path), "A's export was published as B's")

        // B finishes: its own bytes, at its own destination.
        try Data().write(to: releaseB)
        #expect(await PersonRefreshAppFixtures.waitUntil(8) {
            if case .waiting = b.phase { return false }
            return true
        })
        #expect((try? Data(contentsOf: outB)) == bytesB, "B published something other than its own export")
        a.cancel(); b.cancel()
    }

    // The same shape on "Refresh from FamilySearch…" (flake 2026-11-24, M4
    // suite on 35d23778e: FamilyTreeReadOnlyClosing2Tests' F3 never reached
    // .ready). Its scratch answer path was `<scratch>/<FSID>-<second>/
    // person.ged` — unique within ONE refresh root only. Two refreshes of the
    // same person in the same second under two roots (parallel tests, two
    // test hosts sharing one TMPDIR) shared it: one run read the other's
    // answer. Deterministic here: one clock second, one scratch root.
    @Test func twoPersonRefreshesInOneSecondNeverShareAnAnswerFile() async throws {
        let second = Date(timeIntervalSince1970: 1_790_000_000)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsrefresh-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func refresh(_ tag: String) throws -> (PersonRefreshCoordinator, PersonRefreshAppFixtures.Layout) {
            let layout = try PersonRefreshAppFixtures.layout(tag: tag)
            let seed = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
            seed.personRefreshOverlayStore = layout.overlayStore
            seed.loadNow()
            let target = try #require(seed.personRefreshTarget(for: "@I1@"))
            let c = PersonRefreshCoordinator(
                target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
                installedFacts: { seed.personFacts(familySearchID: target.familySearchID) },
                locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
                launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(20),
                sink: PersonRefreshNoteSink(videoscanLog: { _ in }), now: { second })
            c.answerScratchRoot = scratch
            return (c, layout)
        }
        let (a, layoutA) = try refresh("scratch-a"); defer { layoutA.remove() }
        let (b, layoutB) = try refresh("scratch-b"); defer { layoutB.remove() }
        a.launch()
        b.launch()
        defer { a.cancel(); b.cancel() }
        guard case .waiting(let outA) = a.phase, case .waiting(let outB) = b.phase else {
            Issue.record("not waiting: \(a.phase) / \(b.phase)"); return
        }
        #expect(outA != outB, "two runs were handed one answer file: \(outA.path)")
        // B's answer lands first — and it is the wrong person (a refusal).
        try PersonRefreshAppFixtures.onePerson(fsid: "ZZZZ-999").write(to: outB, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { b.isSettled })
        #expect({ if case .waiting = a.phase { return true }; return false }(), "A read B's answer: \(a.phase)")
        // A's own answer: A reaches review.
        try PersonRefreshAppFixtures.onePerson().write(to: outA, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .ready = a.phase { true } else { false } },
                "A: \(a.phase)")
    }

    // Codex P2 on d91d4503e (disk rule, DECISIONS 2026-11-23): each launch
    // left its scratch folder and person.ged behind — after a publish, a
    // cancel, a refused publish. The launch frees what it allocated; the
    // published copy under the refresh root stays.
    private final class Mode: @unchecked Sendable { var value: FamilyTreeAccessMode = .full }

    private func scratchLaunch(_ tag: String, scratch: URL, mode: Mode)
        throws -> (PersonRefreshCoordinator, PersonRefreshAppFixtures.Layout, URL) {
        let layout = try PersonRefreshAppFixtures.layout(tag: tag)
        let seed = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        seed.personRefreshOverlayStore = layout.overlayStore
        seed.loadNow()
        let target = try #require(seed.personRefreshTarget(for: "@I1@"))
        let c = PersonRefreshCoordinator(
            target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
            installedFacts: { seed.personFacts(familySearchID: target.familySearchID) },
            locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
            launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(20),
            sink: PersonRefreshNoteSink(videoscanLog: { _ in }))
        c.answerScratchRoot = scratch
        c.writeMode = { mode.value }
        c.launch()
        guard case .waiting(let output) = c.phase else { throw CancellationError() }
        return (c, layout, output)
    }

    private func leftovers(_ scratch: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
    }

    @Test func aPublishedRefreshFreesItsScratchAndKeepsThePublishedCopy() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (c, layout, output) = try scratchLaunch("free-publish", scratch: scratch, mode: Mode())
        defer { layout.remove(); c.cancel() }
        try PersonRefreshAppFixtures.onePerson().write(to: output, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .ready = c.phase { true } else { false } }, "\(c.phase)")
        #expect(leftovers(scratch).isEmpty, "the launch left \(leftovers(scratch)) in scratch")
        let published = try #require(c.stagingFolder).appendingPathComponent(PersonRefreshPaths.outputFileName)
        #expect(FileManager.default.fileExists(atPath: published.path), "the published copy is the record")
    }

    @Test func aCancelledRefreshFreesItsScratch() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (c, layout, _) = try scratchLaunch("free-cancel", scratch: scratch, mode: Mode())
        defer { layout.remove() }
        #expect(!leftovers(scratch).isEmpty, "precondition: the launch made its folder")
        c.cancel()
        #expect(leftovers(scratch).isEmpty, "the launch left \(leftovers(scratch)) in scratch")
    }

    @Test func aRefusedPublishFreesItsScratchAndLandsNothing() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let mode = Mode()
        let (c, layout, output) = try scratchLaunch("free-refused", scratch: scratch, mode: mode)
        defer { layout.remove(); c.cancel() }
        mode.value = .readOnly(.viewer)          // revoked before the answer is published
        try PersonRefreshAppFixtures.onePerson().write(to: output, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .failed = c.phase { true } else { false } }, "\(c.phase)")
        #expect(leftovers(scratch).isEmpty, "the launch left \(leftovers(scratch)) in scratch")
        let published = try #require(c.stagingFolder).appendingPathComponent(PersonRefreshPaths.outputFileName)
        #expect(!FileManager.default.fileExists(atPath: published.path), "a refused publish landed the answer")
    }

    // Codex closing pass on 84e7a599f, P1: the cleanup checked the folder's
    // TYPE, not its identity — a folder moved into its place was deleted.
    @Test func aFolderSwappedInUnderTheScratchNameSurvivesCancel() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let (c, layout, output) = try scratchLaunch("free-swap", scratch: scratch, mode: Mode())
        defer { layout.remove() }
        let launchFolder = output.deletingLastPathComponent().deletingLastPathComponent()
        // The launch's folder renamed aside; a look-alike (same names, a
        // sentinel answer) moved into its path.
        try fm.moveItem(at: launchFolder, to: scratch.appendingPathComponent("aside", isDirectory: true))
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "sentinel".write(to: output, atomically: true, encoding: .utf8)
        c.cancel()
        #expect((try? String(contentsOf: output, encoding: .utf8)) == "sentinel", "cleanup deleted a folder it did not make")
    }

    @Test func aScratchHoldingWhatTheLaunchDidNotMakeIsLeftWhole() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let (c, layout, output) = try scratchLaunch("free-extra", scratch: scratch, mode: Mode())
        defer { layout.remove() }
        let stranger = output.deletingLastPathComponent().appendingPathComponent("not-ours.txt")
        try "keep".write(to: stranger, atomically: true, encoding: .utf8)
        c.cancel()
        #expect(fm.fileExists(atPath: stranger.path), "cleanup removed a file the launch did not make")
    }

    // P2: one coordinator, A's answer being parsed, relaunched as B before
    // yielding — A's parser must neither set B's phase nor free B's scratch.
    @Test func aRelaunchMidParseKeepsTheNewLaunchAndItsScratch() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("fsrefresh-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let (c, layout, outA) = try scratchLaunch("free-relaunch", scratch: scratch, mode: Mode())
        defer { layout.remove(); c.cancel() }
        try PersonRefreshAppFixtures.onePerson().write(to: outA, atomically: true, encoding: .utf8)
        c.read(output: outA)             // A's parse is now in flight
        c.launch()                       // B, before A's parser can finish
        guard case .waiting(let outB) = c.phase, outB != outA else { Issue.record("B not waiting: \(c.phase)"); return }
        // A's parse takes milliseconds; a stale completion would end B's wait.
        let ended = await PersonRefreshAppFixtures.waitUntil(1) { if case .waiting = c.phase { false } else { true } }
        #expect(!ended, "A's stale parse changed B's phase to \(c.phase)")
        #expect(fm.fileExists(atPath: outB.deletingLastPathComponent().path), "B's scratch was freed before B answered")
        try PersonRefreshAppFixtures.onePerson().write(to: outB, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .ready = c.phase { true } else { false } }, "B: \(c.phase)")
    }
}
