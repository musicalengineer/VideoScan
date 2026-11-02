// FamilyTreeReadOnlyClosing3Tests.swift
// Codex cycle #196 (BLOCK, 3 × P1), each pinned by Codex's proposed
// regression, seen RED before the fix:
//   F1 — a document removal held after the model's check: the model is
//        configured unavailable (the published centre stays available) and
//        the removal must still move nothing.
//   F2 — the crest picker's store, taken exactly as the tab takes it, then
//        the archive revoked while the picker is open: no crest, no folder,
//        never the absent mount point.
//   F3 — person-refresh output written by the spawned tool after a
//        revocation must not land in the refresh root.

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScanCore
@testable import VideoScan

private func waitOn(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { semaphore.wait(); c.resume() }
    }
}

private func pngData() throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}

private func pdfData() throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 10, y: 10, width: 50, height: 20))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

/// Runs the Terminal script the way Terminal would: zsh, Return pressed.
private struct RunningLauncher: FamilySearchPullLauncher {
    let environment: [String: String]
    func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [url.path]
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

@Suite("Family Tree read-only — closing #196", .serialized)
@MainActor
struct FamilyTreeReadOnlyClosing3Tests {

    // -- F1: removal held after the model's check --

    @Test func aDocumentRemovalHeldWhileTheModelGoesReadOnlyMovesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        let live = centre.makeLiveStore()
        let person = FamilyAssetPerson(gedcomID: fx.rootPersonID, name: "Root")
        let graph = try #require(fx.store().loadCurrent()?.graph)
        let rootPerson = FamilyAssetPerson(try #require(graph.people[fx.rootPersonID]))
        let source = fx.root.appendingPathComponent("birth.pdf")
        try pdfData().write(to: source)
        _ = try live.importPersonDocument(from: source, kind: .birth, note: "",
                                          into: try live.folderForPhotoRequest(person: rootPerson), for: rootPerson)
        _ = person
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var held = live
        held.importClock = {
            started.signal()
            release.wait()
            return Date(timeIntervalSince1970: 1_790_000_000)
        }
        let heldStore = held
        let model = FamilyTreeLiveModel(originalsDirectory: live.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped },
                                        documentStoreProvider: { heldStore }, configurationCenter: centre)
        let full = FamilyAssetConfiguration(roots: .init(assets: live.root, thumbnailCache: live.cacheRoot),
                                            access: .readWrite, legacyGEDCOMDirectory: nil)
        await model.prepareForAppearance(revision: "full", source: full, settings: settings)
        model.select(fx.rootPersonID)
        #expect(await PersonRefreshAppFixtures.waitUntil { !model.selectedDocuments.isEmpty })
        let row = try #require(model.selectedDocuments.first)
        let removal = Task { await model.removeDocument(row) }
        await waitOn(started)                                   // past the model's check, inside the store
        model.configure(source: FamilyAssetConfiguration(roots: full.roots, access: .unavailable,
                                                         legacyGEDCOMDirectory: nil))
        #expect(model.accessMode.isReadOnly)
        let at = try revocationSnapshot(fx.root)
        release.signal()
        _ = await removal.value
        #expect(try revocationSnapshot(fx.root) == at, "the document moved after the model went read-only")
    }

    // -- F2: the crest picker's store --

    @Test func theCrestPickersStoreRefusesOnceTheArchiveIsRevoked() throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        let store = FamilyCrestsPane.writerStore(center: centre)      // exactly as the tab takes it
        let image = fx.root.appendingPathComponent("crest.png")
        try pngData().write(to: image)
        // The picker is open; the archive goes.
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
        let at = try revocationSnapshot(fx.root)
        #expect(throws: (any Error).self) { _ = try store.importCrest(from: image, surname: "Breen") }
        #expect(try revocationSnapshot(fx.root) == at, "a crest landed after the revocation")
        // Unplugged too: the mount point must stay absent.
        try fx.unplug()
        #expect(throws: (any Error).self) { _ = try store.importCrest(from: image, surname: "Breen") }
        #expect(!FileManager.default.fileExists(atPath: fx.archive.path), "the absent mount point was created")
    }

    // -- F3: the spawned tool's output after a revocation --

    @Test func aRefreshToolThatWritesAfterRevocationLandsNothingInTheRefreshRoot() async throws {
        let layout = try PersonRefreshAppFixtures.layout(tag: "ro-terminal")
        defer { layout.remove() }
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.personRefreshOverlayStore = layout.overlayStore
        model.loadNow()
        let target = try #require(model.personRefreshTarget(for: "@I1@"))
        // A fixture getmyancestors: waits for a release file, then writes -o.
        let answer = layout.base.appendingPathComponent("answer.ged")
        try PersonRefreshAppFixtures.onePerson().write(to: answer, atomically: true, encoding: .utf8)
        let releaseFile = layout.base.appendingPathComponent("release")
        let tool = layout.bin.appendingPathComponent("slow-getmyancestors")
        try """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        i=0
        while [ ! -f "$RELEASE" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
        mkdir -p "$(dirname "$out")"
        cp "$FIXTURE" "$out"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let box = ReadOnlyModeBox()
        let coordinator = PersonRefreshCoordinator(
            target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
            installedFacts: { model.personFacts(familySearchID: target.familySearchID) },
            locator: FamilySearchToolLocator(overridePath: tool.path, candidatePaths: []),
            launcher: RunningLauncher(environment: ["RELEASE": releaseFile.path, "FIXTURE": answer.path]),
            pollInterval: .milliseconds(20),
            sink: PersonRefreshNoteSink(videoscanLog: { _ in }))
        coordinator.writeMode = { box.mode }
        coordinator.launch()
        guard case .waiting = coordinator.phase else { Issue.record("\(coordinator.phase)"); return }
        try await Task.sleep(for: .milliseconds(300))           // the tool is running, waiting
        box.set(.readOnly(.archiveUnavailable))
        let at = try revocationSnapshot(layout.refreshRoot)
        try Data().write(to: releaseFile)                        // the tool now writes its output
        _ = await PersonRefreshAppFixtures.waitUntil(5) {
            if case .waiting = coordinator.phase { return false }
            return true
        }
        try await Task.sleep(for: .milliseconds(200))
        coordinator.cancel()
        #expect(try revocationSnapshot(layout.refreshRoot) == at, "the tool's answer landed after the revocation")
    }
}
