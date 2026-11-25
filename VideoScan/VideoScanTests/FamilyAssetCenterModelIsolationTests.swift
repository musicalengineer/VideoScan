// FamilyAssetCenterModelIsolationTests.swift
// GH #511 — a VideoScanModel built by a test published its Master Archive
// authority into the process-wide FamilyAssetConfigurationCenter.shared.
// A test that designates an offline archive (DossierArchivedAdmissionTests,
// CatalogOffMainTotals*, CatalogTrashOnlyCopyAtTheMove…) left `.shared`
// reading `.unavailable` with that test's roots, and every suite the shard
// deal put after it in the same host saw research / document / bookmark
// writes refused: RecordFinderFiling (26 M4 REDs 11/23),
// FamilyTreeBookmarkDiscovery, WikipediaVetting, ResearchStore. Order-
// dependent, so it flaked as the shard timings moved.
//
// Fix: the model publishes into `familyAssetCenter` — `.shared` for the
// app's one model (unchanged), a private centre per model in a unit-test
// process.
//
//   LOGIC      an offline designation on a test's model reaches the model's
//              own centre (truth kept) and not `.shared`; the process gate
//              still allows research writes; injection publishes where told.
//   PRODUCTION the factory hands the app (not a unit-test process) `.shared`.
//   SCALE      200 models, each designating an offline archive: `.shared`
//              untouched, under a time budget.
//   ISOLATION  a poisoned `.shared`-shaped centre on one model never reaches
//              another model's centre.
//   SENSOR     source pin: no app source publishes into `.shared` except
//              the standalone Hallie shell (no model there).
//
// Suites (filter by SUITE): FamilyAssetCenterModelIsolationTests

import Foundation
import Testing
@testable import VideoScan

@Suite("GH #511 — a test's VideoScanModel never publishes into the process-wide family-asset centre")
@MainActor
struct FamilyAssetCenterModelIsolationTests {

    /// A designation whose root does not exist: the model publishes
    /// `.unavailable` (designated but offline) — exactly the victim-maker.
    private static func offlineDesignation() -> MasterArchiveDesignation {
        let target = "/Volumes/TestGH511Offline_\(UUID().uuidString.prefix(8))"
        return MasterArchiveDesignation(targetPath: target, rootPath: target + "/Breen_Family_Archive")
    }

    // MARK: LOGIC — RED before the fix

    /// RED before the fix: the model's didSet published `.unavailable`
    /// into `.shared`, so the process-wide gate refused research writes —
    /// the ResearchStore victims' exact refusal.
    @Test func anOfflineArchiveOnATestModelLeavesTheProcessGateOpen() throws {
        let model = VideoScanModel()
        model.masterArchive = Self.offlineDesignation()

        let shared = FamilyAssetConfigurationCenter.shared.snapshot()
        #expect(shared.access != .unavailable,
                "a test's model left FamilyAssetConfigurationCenter.shared reading .unavailable")
        #expect(!shared.roots.assets.path.hasPrefix("/Volumes/TestGH511Offline_"),
                "a test's model published its archive roots into .shared: \(shared.roots.assets.path)")
        #expect(FamilyTreeAccessMode.current() == .full)
        #expect(throws: Never.self) {
            try FamilyTreeWriteAuthority.process.check(.research, path: "gh511-victim-check", log: { _ in })
        }
    }

    /// RED before the fix: the same, through the RecordFinderFiling victim's
    /// writer (documents) and the bookmark victim's writer.
    @Test func documentAndBookmarkWritersAreNotRefusedAfterAModelDesignatesOffline() throws {
        let model = VideoScanModel()
        model.masterArchive = Self.offlineDesignation()
        model.reresolveMasterArchiveMount()   // publishes again (the load path)

        for writer in [FamilyTreeWriter.document, .bookmark, .research] {
            #expect(!FamilyTreeWriteGate.refuse(writer, path: "gh511-\(writer)",
                                                mode: FamilyTreeAccessMode.current(), log: { _ in }),
                    "\(writer.noun) refused by state another test's model published")
        }
    }

    // MARK: LOGIC — the model's own truth is kept

    /// The fix must not silence the model: its own centre carries the
    /// offline designation (`.unavailable`, the archive's roots).
    @Test func theModelsOwnCentreStillReadsUnavailable() {
        let model = VideoScanModel()
        #expect(model.familyAssetCenter !== FamilyAssetConfigurationCenter.shared,
                "a unit-test model must own its centre")
        let designation = Self.offlineDesignation()
        model.masterArchive = designation
        let own = model.familyAssetCenter.snapshot()
        #expect(own.access == .unavailable)
        #expect(own.roots.assets.path.hasPrefix(designation.rootPath))
        #expect(FamilyTreeAccessMode.current(configuration: model.familyAssetCenter) == .readOnly(.archiveUnavailable))

        // Archive back (designation cleared): the model's centre follows.
        model.masterArchive = nil
        #expect(model.familyAssetCenter.snapshot().access != .unavailable)
    }

    /// An injected centre is where the model publishes — the seam a test
    /// uses when it wants a reader to see the model's authority.
    @Test func anInjectedCentreReceivesThePublish() {
        let centre = FamilyAssetConfigurationCenter()
        let model = VideoScanModel(familyAssetCenter: centre)
        #expect(model.familyAssetCenter === centre)
        model.masterArchive = Self.offlineDesignation()
        #expect(centre.snapshot().access == .unavailable)
        #expect(FamilyTreeAccessMode.current(configuration: centre) == .readOnly(.archiveUnavailable))
    }

    // MARK: PRODUCTION — the app's one model still publishes into `.shared`

    @Test func theAppProcessModelPublishesIntoTheSharedCentre() {
        #expect(FamilyAssetConfigurationCenter.forNewModel(isUnitTestProcess: false)
                === FamilyAssetConfigurationCenter.shared)
        let a = FamilyAssetConfigurationCenter.forNewModel(isUnitTestProcess: true)
        let b = FamilyAssetConfigurationCenter.forNewModel(isUnitTestProcess: true)
        #expect(a !== FamilyAssetConfigurationCenter.shared)
        #expect(a !== b, "each test model gets its own centre")
        // The live default in this (unit-test) process is the private one.
        #expect(FamilyAssetConfigurationCenter.forNewModel() !== FamilyAssetConfigurationCenter.shared)
    }

    // MARK: SCALE

    /// 200 models (more than any one shard builds), each designating an
    /// offline archive and re-resolving it: `.shared` stays as a fresh
    /// process left it, and the whole loop stays inside a generous budget.
    @Test func twoHundredModelsWithOfflineArchivesLeaveTheProcessCentreAlone() {
        let start = ContinuousClock.now
        var models: [VideoScanModel] = []
        for _ in 0..<200 {
            let model = VideoScanModel()
            model.masterArchive = Self.offlineDesignation()
            models.append(model)
        }
        let elapsed = ContinuousClock.now - start
        #expect(models.allSatisfy { $0.familyAssetCenter.snapshot().access == .unavailable })
        #expect(FamilyAssetConfigurationCenter.shared.snapshot().access != .unavailable)
        #expect(FamilyTreeAccessMode.current() == .full)
        #expect(elapsed < .seconds(20), "200 models took \(elapsed)")
    }

    // MARK: ISOLATION

    /// Poisoned state on one model's centre (offline archive + a stale
    /// identity) never reaches a model built after it.
    @Test func aPoisonedModelCentreNeverReachesTheNextModel() {
        let poisoned = VideoScanModel()
        poisoned.masterArchive = Self.offlineDesignation()
        #expect(poisoned.familyAssetCenter.snapshot().access == .unavailable)

        let next = VideoScanModel()
        #expect(next.familyAssetCenter !== poisoned.familyAssetCenter)
        #expect(next.familyAssetCenter.snapshot().access != .unavailable)
        #expect(!next.familyAssetCenter.snapshot().roots.assets.path.hasPrefix("/Volumes/TestGH511Offline_"))
    }

    // MARK: SENSOR — source pin

    /// The only app source that may publish into `.shared` directly is the
    /// standalone Hallie shell (`--hallie`, no VideoScanModel in that
    /// process). A model path that wrote `.shared` again would bring back
    /// the order dependency; this fails first.
    @Test func onlyTheHallieShellPublishesIntoTheSharedCentreDirectly() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
        let allowed: Set<String> = ["HallieShellCLI.swift"]
        let pattern = try NSRegularExpression(pattern: #"FamilyAssetConfigurationCenter\s*\.shared\s*\.publish\("#)
        var offenders: [String] = []
        var scanned = 0
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if pattern.firstMatch(in: text, range: range) != nil, !allowed.contains(url.lastPathComponent) {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 500, "the sensor must actually read the app sources (read \(scanned))")
        #expect(offenders.isEmpty, "publishes into FamilyAssetConfigurationCenter.shared: \(offenders)")
        let model = try String(contentsOf: app.appendingPathComponent("FamilyTree/VideoScanModel+FamilyAssets.swift"),
                               encoding: .utf8)
        #expect(model.contains("familyAssetCenter.publish("))
    }
}
