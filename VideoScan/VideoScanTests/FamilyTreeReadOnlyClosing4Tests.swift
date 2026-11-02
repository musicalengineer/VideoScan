// FamilyTreeReadOnlyClosing4Tests.swift
// Codex cycle #198 (BLOCK, 2 × P1), each pinned by Codex's proposed
// regression, seen RED before the fix:
//   F1 — Get Family Tree's spawned tool writes where it is told (its -o) and
//        beside its working directory; after a revocation nothing may land
//        under family data or the chosen output folder except through the
//        permit.
//   F2 — an open Adjust Photo sheet whose MODEL went read-only (the published
//        centre still available) must refuse its Save: UI saves run under the
//        model's authority, never the process's.

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScanCore
@testable import VideoScan

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

/// Runs a Terminal script the way Terminal would: zsh, Return pressed, in a
/// working directory the test chooses (as Terminal's would be: $HOME).
private struct ScriptRunner: FamilySearchPullLauncher {
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

@Suite("Family Tree read-only — closing #198", .serialized)
@MainActor
struct FamilyTreeReadOnlyClosing4Tests {

    // -- F1: the pull's spawned tool --

    @Test func aPullToolThatWritesAfterRevocationLandsNothingOutsideThePermit() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let downloads = fx.root.appendingPathComponent("Downloads", isDirectory: true)
        let home = fx.root.appendingPathComponent("Home", isDirectory: true)       // Terminal's cwd
        let bin = fx.root.appendingPathComponent("bin", isDirectory: true)
        for d in [downloads, home, bin] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let answer = fx.root.appendingPathComponent("answer.ged")
        try ReadOnlyFixture.gedcom(people: 8, generations: 2).write(to: answer, atomically: true, encoding: .utf8)
        let release = fx.root.appendingPathComponent("release")
        let tool = bin.appendingPathComponent("getmyancestors")
        try """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        i=0
        while [ ! -f "$RELEASE" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
        cp "$FIXTURE" "$out"
        echo "settings" > ./getmyancestors.side
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let box = ReadOnlyModeBox()
        let c = FamilySearchPullCoordinator(
            gedcomDirectory: fx.gedcomDirectory, defaultUsername: "rick@example.com",
            scriptURL: fx.familyTree.appendingPathComponent("get-family-tree.command"),
            stagingDirectory: fx.familyTree.appendingPathComponent("staging"),
            locator: FamilySearchToolLocator(overridePath: tool.path),
            launcher: ScriptRunner(environment: ["RELEASE": release.path, "FIXTURE": answer.path],
                                   workingDirectory: home),
            pollInterval: .milliseconds(30))
        c.compiledStore = { nil }
        c.writeMode = { box.mode }
        c.request.outputURL = downloads.appendingPathComponent("familysearch-tree.ged")
        c.launch()
        guard case .waiting = c.phase else { Issue.record("\(c.phase)"); return }
        try await Task.sleep(for: .milliseconds(300))           // the tool is running, waiting
        box.set(.readOnly(.archiveUnavailable))
        let at = try revocationSnapshot(fx.root)
        try Data().write(to: release)                            // the tool writes now
        try await Task.sleep(for: .milliseconds(1_200))
        c.cancel()
        var after = try revocationSnapshot(fx.root)
        after["/release"] = nil
        #expect(after == at, "the tool's output landed outside the permit: \(Set(after.keys).symmetricDifference(at.keys))")
    }

    // -- F2: an open Adjust sheet whose model went read-only --

    private func pngData() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func anOpenAdjustSheetRefusesAfterOnlyItsModelIsRevoked() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        let live = centre.makeLiveStore()
        let model = FamilyTreeLiveModel(originalsDirectory: live.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped }, configurationCenter: centre)
        let full = FamilyAssetConfiguration(roots: .init(assets: live.root, thumbnailCache: live.cacheRoot),
                                            access: .readWrite, legacyGEDCOMDirectory: nil)
        await model.prepareForAppearance(revision: "full", source: full, settings: settings)
        let data = try pngData()
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // As FamilyTreeView presents it.
        let source = FamilyPhotoAdjustSource(
            personID: fx.rootPersonID, personName: "Root",
            assetPerson: FamilyAssetPerson(gedcomID: fx.rootPersonID, name: "Root"),
            image: image, originalURL: nil, makeStore: { live }, writeAuthority: { model.writeAuthority })
        // The sheet is open; only the MODEL goes read-only.
        model.configure(source: FamilyAssetConfiguration(roots: full.roots, access: .unavailable,
                                                         legacyGEDCOMDirectory: nil))
        #expect(model.accessMode.isReadOnly)
        let at = try revocationSnapshot(fx.root)
        #expect(throws: (any Error).self) { _ = try FamilyPhotoAdjustSheet.saveCrop(data, source: source) }
        #expect(try revocationSnapshot(fx.root) == at, "the crop was saved although the model is read-only")
    }
}
