// FamilyTreeReadOnlyClosing5Tests.swift
// Codex cycle #199 (BLOCK, 1 × P1): Get Family Tree's scratch path was keyed
// by pid + output basename, so two pulls with different chosen destinations
// shared it — a forgotten pull A could finish and be published as pull B's
// export. Regression (Codex's), seen RED before the fix: two held runs A and
// B; release A → B still waiting, its output absent; release B → B's bytes.

import Testing
import Foundation
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
}
