// FamilyTreeReadOnlyClosingTests.swift
// Codex closing cycle #192 (BLOCK, 4 × P1, all F2 — "writers re-check at the
// moment of the write"), each pinned by Codex's proposed regression, seen RED
// before the fix:
//   F2 — an ordinary load and a merge's base load hand the loader a store
//        that carries the LIVE guard: a revocation while they run promotes
//        nothing (snapshot at revocation == after).
//   F3 — a captured CyberBrain recorder asks the model's live authority at
//        each record (injected centre AND the model's own access).
//   F4 — a live photo store checks before its first byte: revoked during
//        `choosePhoto`, no portrait file lands.
// (F1, the Core store's promotion-time guard, is in VideoScanCore's
// FamilyGraphCompiledStoreWriteGuardTests.)

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VideoScanCore
@testable import VideoScan

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

private func publishedCentre(_ fx: ReadOnlyFixture, available: Bool) -> FamilyAssetConfigurationCenter {
    let c = FamilyAssetConfigurationCenter()
    c.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: available, readOnly: false)
    return c
}

@Suite("Family Tree read-only — closing #192", .serialized)
@MainActor
struct FamilyTreeReadOnlyClosingTests {

    // -- F2: an ordinary full-mode load revoked while it compiles --

    @Test func aLoadRevokedWhileItCompilesANewerPullPromotesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        // A newer, distinct pull beside the compiled one: the loader will
        // parse and promote it (rule 1).
        let newer = fx.gedcomDirectory.appendingPathComponent("newer.ged")
        try ReadOnlyFixture.gedcom(people: 50, generations: 4)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID Z").write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: newer.path)
        let centre = publishedCentre(fx, available: true)
        var store = fx.store()
        let verify = store.verify
        final class Snap: @unchecked Sendable { var at: [String: String]? }
        let snap = Snap()
        let root = fx.root
        store.verify = { decoded, source in
            centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
            snap.at = try? revocationSnapshot(root)
            return verify(decoded, source)
        }
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: store,
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped }, configurationCenter: centre)
        await model.loadFromDisk(settings: settings)
        let at = try #require(snap.at, "the compile never reached verification — the test did not revoke")
        #expect(try revocationSnapshot(fx.root) == at, "the load promoted after the revocation")
    }

    // -- F2: a merge's base load, revoked before the main actor yields --

    @Test func aMergeRevokedBeforeItsBaseLoadCompilesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let empty = fx.root.appendingPathComponent("AppSupport/VideoScan/family-tree/empty-compiled")
        let downloads = fx.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let download = downloads.appendingPathComponent("familysearch-new.ged")
        try ReadOnlyFixture.gedcom(people: 8, generations: 2)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID N").write(to: download, atomically: true, encoding: .utf8)
        let box = ReadOnlyModeBox()
        let c = FamilySearchPullCoordinator(
            gedcomDirectory: fx.gedcomDirectory, defaultUsername: "rick@example.com",
            scriptURL: downloads.appendingPathComponent("get-family-tree.command"),
            stagingDirectory: fx.familyTree.appendingPathComponent("staging"),
            locator: FamilySearchToolLocator(overridePath: "/nonexistent/getmyancestors"),
            launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(30))
        c.compiledStore = {
            var s = FamilyGraphCompiledStore(root: empty)
            s.log = { _ in }
            return s
        }
        c.writeMode = { box.mode }
        c.installFromFile(download)
        for _ in 0..<400 {
            if case .ready = c.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready = c.phase else { Issue.record("not ready: \(c.phase)"); return }
        let task = c.installMerged()          // entry gate: allowed
        box.set(.readOnly(.archiveUnavailable)) // revoked before the main actor yields
        let at = try revocationSnapshot(fx.root)
        await task.value
        #expect(try revocationSnapshot(fx.root) == at, "the merge's base load compiled after the revocation")
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }

    // -- F3: the captured recorder obeys the live authority --

    @Test func aCapturedRecorderRefusesAfterTheInjectedCentreIsRevoked() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = publishedCentre(fx, available: true)
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped }, configurationCenter: centre)
        await model.prepareForAppearance(revision: "full", source: fx.configuration(access: .readWrite),
                                         settings: settings)
        let record = try #require(model.cyberBrainRecorder())
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
        let before = try revocationSnapshot(fx.brain)
        let t = CyberBrainWriter.Testimony(subjectName: "Anyone", subjectAliases: [], speakerName: "Rick",
                                           text: "after revocation", date: Date())
        #expect(throws: (any Error).self) { _ = try record(t) }
        #expect(try revocationSnapshot(fx.brain) == before)
    }

    @Test func aCapturedRecorderRefusesAfterTheModelIsConfiguredUnavailable() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped },
                                        configurationCenter: FamilyAssetConfigurationCenter())
        await model.prepareForAppearance(revision: "full", source: fx.configuration(access: .readWrite),
                                         settings: settings)
        let record = try #require(model.cyberBrainRecorder())
        model.configure(source: fx.configuration(access: .unavailable))
        let before = try revocationSnapshot(fx.brain)
        let t = CyberBrainWriter.Testimony(subjectName: "Anyone", subjectAliases: [], speakerName: "Rick",
                                           text: "after revocation", date: Date())
        #expect(throws: (any Error).self) { _ = try record(t) }
        #expect(try revocationSnapshot(fx.brain) == before)
    }

    // -- F4: a live photo store checks before the first byte --

    private func pngData() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func aLivePhotoStoreRevokedMidChooseWritesNoPortrait() throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        var store = centre.makeLiveStore()
        // The live store's roots are the centre's (App Support under the
        // test host); snapshot them from the moment of revocation.
        final class Snap: @unchecked Sendable { var at: [String: String]? }
        let snap = Snap()
        let root = store.root
        store.importClock = {
            centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
            snap.at = try? revocationSnapshot(root)
            return Date(timeIntervalSince1970: 1_790_000_000)
        }
        let person = FamilyAssetPerson(gedcomID: "@I0_0@", name: "Root Person")
        #expect(throws: (any Error).self) {
            _ = try store.choosePhoto(try pngData(), fileExtension: "png", for: person, source: "test")
        }
        let at = try #require(snap.at, "the clock was never read — the test did not revoke")
        #expect(try revocationSnapshot(root) == at, "a portrait landed after the revocation")
    }
}
