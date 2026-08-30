// RemoteViewerReadOnlySensorTests.swift
// Phase 1 remote use, slice 4 — the viewer UI and the read-only
// enforcement sensor (docs/remote_use_design.md §4/§5).
//
// Every write path a viewer could reach is enumerated here and asserted
// to REFUSE in viewer mode with a log line naming it:
//   CatalogStore.saveNow / scheduleSave, POIProfile.save,
//   FamilyTreeLiveModel CyberBrain writers, ResearchStore persistence,
//   Hallie's live testimony/photo/drill/exclusion writers, Pronunciation.record,
//   FamilyGraphCompiledStore ingest/rollback (the app store),
//   FamilyTreeLiveModel.recompile, MediaFileOperationsCenter.add (every
//   MFO kind funnels through it), FamilySearchPull launch/install.
// And the mirror: in master mode none of them is refused and nothing is
// logged (the master sensor). The chip wording is pinned too.
//
// The process-wide ViewerModeCenter is installed with an injected log
// sink and reset in `defer`; the suite is serialized.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    func has(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
}

private func tmp(_ tag: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("viewer-ro-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Suite(.serialized)
struct RemoteViewerReadOnlySensorTests {

    @Test func everyWritePathRefusesInViewerModeWithALogLine() async throws {
        let sink = Sink()
        ViewerModeCenter.shared.reset(sink: { sink.append($0) })
        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        defer { ViewerModeCenter.shared.reset() }
        let root = tmp("paths")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hint = "on the master (RicksM4)"
        let ged = root.appendingPathComponent("originals/family.ged")
        try FileManager.default.createDirectory(
            at: ged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GedcomSyntheticPedigree.gedcom(people: 20, generations: 3)
            .write(to: ged, atomically: true, encoding: .utf8)
        let graph = try #require(GedcomFamilyGraph(fileURL: ged))

        // 1. CatalogStore — the data layer, with the viewer flag the sync engine sets.
        let store = CatalogStore(directory: root.appendingPathComponent("catalog"))
        store.isReadOnly = true
        #expect(store.saveNow(records: [VideoRecord()]) == false)
        store.scheduleSave(records: [VideoRecord()])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog/catalog.json").path))
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) CatalogStore.saveNow — \(hint)"))
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) CatalogStore.scheduleSave — \(hint)"))

        // 2. POIProfile.save (kinship attestations live in profile.json).
        let profile = POIProfile(name: "Viewer Sensor \(UUID().uuidString)", referencePath: root.path)
        #expect(throws: ViewerWriteGuard.RefusedError.self) { try profile.save() }
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) POIProfile.save — \(hint)"))

        assertFamilyTreeWritersRefuse(root: root, sink: sink, hint: hint)
        try assertResearchWritersRefuse(root: root, graph: graph, sink: sink, hint: hint)
        assertHallieWritersRefuse(root: root, sink: sink, hint: hint)

        // 6. Compiled store (the app's store carries the viewer flags) + recompile.
        let appStore = FamilyGraphCompiledStore.app
        #expect(appStore.refusesWrites && appStore.trustsManifestSources)
        var isolated = FamilyGraphCompiledStore(root: root.appendingPathComponent("compiled"))
        let storeLog = Sink()
        isolated.log = { storeLog.append($0) }
        isolated.refusesWrites = true
        #expect(isolated.ingest(graph: graph, sources: [ged]) == nil)
        #expect(isolated.readPointer() == nil, "no generation was written")
        #expect(storeLog.has("\(FamilyGraphCompiledStore.refusedWritePrefix) ingest"))
        #expect(isolated.rollback() == false)
        var loader = FamilyGraphFileLoader(originalsDirectory: ged.deletingLastPathComponent())
        loader.compiledStore = isolated
        #expect(loader.readOnly == true, "the loader defaults to the installed role")
        #expect(loader.loadNewestOutcome().graph == nil, "a viewer never parses a .ged")
        #expect(loader.recompile(sources: [ged]) == nil)
        #expect(storeLog.has("\(FamilyGraphCompiledStore.refusedWritePrefix) recompile"))

        // 7. Media file operations — every kind funnels through add().
        let center = MediaFileOperationsCenter()
        let a = VideoRecord(), b = VideoRecord()
        a.fullPath = "/Volumes/X/a.mov"; a.filename = "a.mov"
        b.fullPath = "/Volumes/X/b.mov"; b.filename = "b.mov"
        let job = center.startCompare(recordA: a, recordB: b)
        #expect(center.jobs.isEmpty, "a refused job is never listed")
        #expect(!center.jobs.contains { $0.id == job.id })
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) MediaFileOperationsCenter.add(PairCompareJob) — \(hint)"))

        // 8. FamilySearch pull.
        let pull = FamilySearchPullCoordinator(gedcomDirectory: root.appendingPathComponent("gedcom"))
        pull.launch()
        pull.install()
        pull.installFromFile(ged)
        _ = pull.installMerged()
        for path in ["FamilySearchPull.launch", "FamilySearchPull.install", "FamilySearchPull.installFromFile", "FamilySearchPull.installMerged"] {
            #expect(sink.has("\(ViewerWriteGuard.logPrefix) \(path) — \(hint)"), Comment(rawValue: path))
        }

        // The center captured the same lines the log sink saw.
        #expect(ViewerModeCenter.shared.refusals.count >= 18)
        #expect(ViewerModeCenter.shared.refusals.allSatisfy { $0.hasPrefix(ViewerWriteGuard.logPrefix) })
    }

    private func assertFamilyTreeWritersRefuse(root: URL, sink: Sink, hint: String) {
        let tree = FamilyTreeLiveModel(
            originalsDirectory: root.appendingPathComponent("originals"),
            cyberBrainRootURL: root.appendingPathComponent("cyberbrain"))
        #expect(throws: ViewerWriteGuard.RefusedError.self) { try tree.addNote("Dad was a Marine.") }
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try tree.recordTestimony(Self.testimony)
        }
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try tree.setPronunciation(word: "McGill", saidAs: "muh-GILL")
        }
        for path in ["FamilyTreeLiveModel.addNote",
                     "FamilyTreeLiveModel.recordTestimony",
                     "FamilyTreeLiveModel.setPronunciation"] {
            #expect(sink.has("\(ViewerWriteGuard.logPrefix) \(path) — \(hint)"), Comment(rawValue: path))
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cyberbrain/cyberbrain.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cyberbrain").path),
            "a refused CyberBrain write must not create its parent directory")
    }

    private func assertResearchWritersRefuse(
        root: URL, graph: GedcomFamilyGraph, sink: Sink, hint: String
    ) throws {
        let research = ResearchStore(peopleRoot: root.appendingPathComponent("people"))
        let subject = ResearchSubject(person: try #require(graph.people.values.first))
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try research.saveDossier(ResearchDossier(subject: subject))
        }
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try research.cache(.init(url: "https://example.test/dad", retrievedAt: Date(),
                                     statusCode: 200, body: Data("page".utf8)), key: subject.key)
        }
        for path in ["ResearchStore.saveDossier", "ResearchStore.cache"] {
            #expect(sink.has("\(ViewerWriteGuard.logPrefix) \(path) — \(hint)"), Comment(rawValue: path))
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("people/\(subject.key)/research").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("people").path),
            "a refused research write must not create any parent path")
    }

    private func assertHallieWritersRefuse(root: URL, sink: Sink, hint: String) {
        let supportRoot = root.appendingPathComponent("isolated-support", isDirectory: true)
        let assetRoot = root.appendingPathComponent("isolated-assets", isDirectory: true)
        let assetStoreCreations = Sink()
        let live = HallieAppTurnCoordinator.Dependencies.makeLive(
            supportRoot,
            HallieLiveAssetStoreFactory {
                assetStoreCreations.append("created")
                return FamilyAssetStore(
                    root: assetRoot,
                    cacheRoot: root.appendingPathComponent("isolated-cache", isDirectory: true))
            })
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try live.recordTestimony(Self.testimony)
        }
        let caption = CyberBrainWriter.PhotoCaption(
            subjects: [.init(name: "Dad")], speakerName: "Rick",
            text: "Dad at home", photoPath: "/tmp/dad.jpg", date: Date())
        #expect(throws: ViewerWriteGuard.RefusedError.self) { try live.recordPhotoCaption(caption) }
        let manifest = PronunciationDrillManifest(
            version: PronunciationDrillStore.currentVersion,
            generatedAt: Date(), entries: [])
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try live.saveDrillStore(PronunciationDrillStore(), manifest)
        }
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try live.recordPronunciation(.init(
                word: "McGill", saidAs: "muh-GILL",
                target: .cyberBrainPerson(id: "x", name: "McGill")))
        }
        _ = live.loadLexicon()
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try live.excludePhoto(root.appendingPathComponent("dad.jpg"), "K1", "Rick", "not Dad")
        }
        for path in ["HallieAppTurnCoordinator.recordTestimony",
                     "HallieAppTurnCoordinator.recordPhotoCaption",
                     "HallieAppTurnCoordinator.saveDrillStore",
                     "Pronunciation.record",
                     "HallieAppTurnCoordinator.loadLexiconDefault",
                     "HallieAppTurnCoordinator.excludePhoto"] {
            #expect(sink.has("\(ViewerWriteGuard.logPrefix) \(path) — \(hint)"), Comment(rawValue: path))
        }
        #expect(assetStoreCreations.all.isEmpty, "the guard runs before asset-store construction")
        #expect(!FileManager.default.fileExists(atPath: supportRoot.path))
        #expect(!FileManager.default.fileExists(atPath: assetRoot.path))
    }

    private static let testimony = CyberBrainWriter.Testimony(
        subjectName: "Dad", speakerName: "Rick", text: "Dad was a Marine.",
        kind: .note, date: Date())

    /// Master sensor: with the default role, none of the guards fires and
    /// nothing is logged — the master's write paths are untouched.
    @Test func masterModeRefusesNothingAndLogsNothing() throws {
        let sink = Sink()
        ViewerModeCenter.shared.reset(sink: { sink.append($0) })
        defer { ViewerModeCenter.shared.reset() }
        let root = tmp("master")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ViewerWriteGuard.refuse("probe") == false)
        #expect(throws: Never.self) { try ViewerWriteGuard.check("probe") }
        let center = MediaFileOperationsCenter()
        let a = VideoRecord(), b = VideoRecord()
        a.fullPath = root.appendingPathComponent("a.mov").path; a.filename = "a.mov"
        b.fullPath = root.appendingPathComponent("b.mov").path; b.filename = "b.mov"
        let job = center.startCompare(recordA: a, recordB: b)
        #expect(center.jobs.contains { $0.id == job.id }, "the master lists and starts the job")
        job.cancel()
        let appStore = FamilyGraphCompiledStore.app
        #expect(!appStore.refusesWrites && !appStore.trustsManifestSources)
        #expect(FamilyGraphFileLoader(originalsDirectory: root).readOnly == false)
        #expect(sink.all.isEmpty)
        #expect(ViewerModeCenter.shared.refusals.isEmpty)
    }

    @Test func statusChipWordingAndMasterOnlyHint() {
        let now = Date()
        #expect(ViewerStatusChipText.compose(masterDisplayName: "RicksM4", syncedAt: now.addingTimeInterval(-120),
                                             syncing: false, media: "streaming", now: now)
                == "Viewing RicksM4's catalog · synced 2 min ago · media: streaming")
        #expect(ViewerStatusChipText.compose(masterDisplayName: "RicksM4", syncedAt: nil, syncing: false,
                                             media: "master offline", now: now)
                == "Viewing RicksM4's catalog · never synced · media: master offline")
        #expect(ViewerStatusChipText.compose(masterDisplayName: "RicksM4", syncedAt: now, syncing: true,
                                             media: "checking…", now: now)
                == "Viewing RicksM4's catalog · syncing… · media: checking…")
        #expect(ViewerStatusChipText.relative(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(ViewerStatusChipText.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 hr ago")
        #expect(ViewerStatusChipText.relative(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago")

        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        defer { ViewerModeCenter.shared.reset() }
        #expect(ViewerModeCenter.shared.masterOnlyHint == "on the master (RicksM4)")
        #expect(ViewerModeCenter.shared.masterDisplayName == "RicksM4")
        #expect(ViewerModeCenter.shortName("ricksm4.LOCAL") == "ricksm4")
    }
}
