// FamilyTreeReadOnlyClosing2Tests.swift
// Codex cycle #193 (BLOCK, 4 × P1 — the check-then-wait-then-write shape):
// each pinned by Codex's proposed regression, seen RED before the fix. The
// fix is one primitive (FamilyTreeWriteAuthority.withWrite / Core
// WritePermit.withWrite) that re-asks the live authority AFTER every lock or
// await, immediately before the bytes.
//   F1 — a captured recorder that waited for the CyberBrain root lock
//   F3 — an overlay retirement revoked before its save
//   F4 — a photo-choice sidecar revoked at its clock read
// (F2, the compiled store's artifact write and cleanup, is in Core's
// FamilyGraphCompiledStoreWriteGuardTests.)

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScanCore
@testable import VideoScan

/// Wait on a semaphore without blocking the main actor.
private func wait(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { semaphore.wait(); c.resume() }
    }
}

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

@Suite("Family Tree read-only — closing #193 (write after a wait)", .serialized)
@MainActor
struct FamilyTreeReadOnlyClosing2Tests {

    // -- F1: the recorder waited for the root lock --

    @Test func aCapturedRecorderRevokedWhileWaitingForRootLockWritesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        try fx.seedNote()      // the archive exists, so the root lock guards a real save
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped }, configurationCenter: centre)
        await model.prepareForAppearance(revision: "full", source: fx.configuration(access: .readWrite),
                                         settings: settings)
        let record = try #require(model.cyberBrainRecorder())
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let brain = fx.brain
        DispatchQueue.global().async {
            CyberBrainWriter.withRootLock(brain) {
                held.signal()
                release.wait()
            }
        }
        await wait(held)
        final class Outcome: @unchecked Sendable { var error: Error?; var wrote = false }
        let outcome = Outcome()
        DispatchQueue.global().async {
            do {
                _ = try record(CyberBrainWriter.Testimony(subjectName: "Anyone", subjectAliases: [],
                                                          speakerName: "Rick", text: "waited", date: Date()))
                outcome.wrote = true
            } catch { outcome.error = error }
            done.signal()
        }
        try await Task.sleep(for: .milliseconds(200))       // the recorder is waiting for the lock
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
        let at = try revocationSnapshot(fx.brain)
        release.signal()
        await wait(done)
        #expect(!outcome.wrote, "the testimony was saved after the revocation")
        #expect(try revocationSnapshot(fx.brain) == at)
    }

    // -- F3: overlay retirement revoked before its save --

    @Test func anOverlayRetirementRevokedBeforeSaveChangesNothing() async throws {
        let layout = try PersonRefreshAppFixtures.layout(tag: "ro-retire")
        defer { layout.remove() }
        // An applied refresh (an overlay entry), through the real path.
        let seed = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        seed.personRefreshOverlayStore = layout.overlayStore
        seed.loadNow()
        let target = try #require(seed.personRefreshTarget(for: "@I1@"))
        let coordinator = PersonRefreshCoordinator(
            target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
            installedFacts: { seed.personFacts(familySearchID: target.familySearchID) },
            locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
            launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(20),
            sink: PersonRefreshNoteSink(videoscanLog: { _ in }))
        coordinator.launch()
        guard case .waiting(let output) = coordinator.phase else { Issue.record("\(coordinator.phase)"); return }
        try PersonRefreshAppFixtures.onePerson().write(to: output, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .ready = coordinator.phase { true } else { false } })
        guard case .ready(let diff) = coordinator.phase else { return }
        #expect(await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key))))
        // A newer full pull supersedes it: the next load retires the entry.
        let tree = layout.gedcom.appendingPathComponent("familysearch-tree.ged")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: tree.path)

        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: layout.base, masterIsSafelyAvailable: true, readOnly: false)
        final class Snap: @unchecked Sendable { var at: [String: String]? }
        let snap = Snap()
        let root = layout.refreshRoot
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom, configurationCenter: centre)
        model.personRefreshOverlayStore = PersonFactOverlayStore(directory: layout.refreshRoot, log: { line in
            if line.contains("retired overlay"), snap.at == nil {
                centre.publish(masterArchiveRoot: layout.base, masterIsSafelyAvailable: false, readOnly: false)
                snap.at = try? revocationSnapshot(root)
            }
        })
        model.loadNow()
        let at = try #require(snap.at, "nothing was retired — the test did not revoke")
        #expect(try revocationSnapshot(layout.refreshRoot) == at, "overlay.json was rewritten after the revocation")
    }

    // -- F4: the choice sidecar revoked at its clock read --

    private func pngData() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func aLivePhotoChoiceRevokedAtImportClockChangesNothing() throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        var store = centre.makeLiveStore()
        let person = FamilyAssetPerson(gedcomID: "@I0_0@", name: "Root Person")
        let first = try store.choosePhoto(try pngData(), fileExtension: "png", for: person, source: "seed",
                                          chosenAt: Date(timeIntervalSince1970: 1_700_000_000))
        final class Snap: @unchecked Sendable { var at: [String: String]? }
        let snap = Snap()
        let root = store.root
        store.importClock = {
            centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
            snap.at = try? revocationSnapshot(root)
            return Date(timeIntervalSince1970: 1_790_000_000)
        }
        #expect(throws: (any Error).self) { try store.recordPhotoChoice(first, for: person, source: "again") }
        let at = try #require(snap.at, "the clock was never read — the test did not revoke")
        #expect(try revocationSnapshot(root) == at, "the choice sidecar was rewritten after the revocation")
    }
}
