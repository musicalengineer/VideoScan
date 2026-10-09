// RemoteViewerReadOnlySensorTests.swift
// Phase 1 remote use, slice 4 — the viewer UI and the read-only
// enforcement sensor (docs/design/remote_use_design.md §4/§5).
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
import AppKit
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

        // 9. Delete Confirmed Junk (C04-F5): the center alone refuses, even
        // with the model flag still false. The file stays on disk.
        let (junkModel, junkRec, junkFile) = try Self.junkFixture(in: root)
        let junkResult = await junkModel.deleteConfirmedJunk([junkRec], mode: .permanent)
        #expect(FileManager.default.fileExists(atPath: junkFile.path))
        #expect(junkRec.purgedAt == nil)
        #expect(junkResult.refused.map(\.record.id) == [junkRec.id])
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) VideoScanModel.deleteConfirmedJunk — \(hint)"))

        // The center captured the same lines the log sink saw.
        #expect(ViewerModeCenter.shared.refusals.count >= 18)
        #expect(ViewerModeCenter.shared.refusals.allSatisfy { $0.hasPrefix(ViewerWriteGuard.logPrefix) })
    }

    private func assertFamilyTreeWritersRefuse(root: URL, sink: Sink, hint: String) {
        let tree = FamilyTreeLiveModel(
            originalsDirectory: root.appendingPathComponent("originals"),
            cyberBrainRootURL: root.appendingPathComponent("cyberbrain"))
        #expect(throws: ViewerWriteGuard.RefusedError.self) { try tree.addNote("Dad was a Marine.", about: "@I1@") }
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
                     "HalliePronunciationLexicon.writeDefault",
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

    @Test func viewerSpeechResolutionKeepsPersonAndShippedLayersWithoutCreatingAFile() throws {
        let root = tmp("speech-lexicon")
        defer { try? FileManager.default.removeItem(at: root) }
        let brainRoot = root.appendingPathComponent("brain", isDirectory: true)
        _ = try CyberBrainWriter.setPronunciation(
            subjectName: "Nathaniel McGill", gedcomPersonID: "@I7@",
            token: "Nathaniel", saidAs: "nah-THAN-yel", rootURL: brainRoot)
        PersonPronunciationCache.shared.invalidate()

        // A conflicting parallel file stands in for poisoned global state.
        // The speech seam receives only the isolated missing path and must
        // neither consult the poison nor create its own parent directory.
        let poison = root.appendingPathComponent("poison/Hallie/pronunciations.json")
        try FileManager.default.createDirectory(
            at: poison.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"Nathaniel":"POISON","Edith":"POISON"}"#.utf8).write(to: poison)
        let missingFile = root.appendingPathComponent("isolated/Hallie/pronunciations.json")
        let sink = Sink()
        ViewerModeCenter.shared.reset(sink: { sink.append($0) })
        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        defer { ViewerModeCenter.shared.reset() }

        let resolved = HallieSpeaker.resolvedLexicon(
            subject: "Nathaniel McGill", fileURL: missingFile,
            cyberBrainRootURL: brainRoot, viewerMode: true)
        #expect(resolved.apply(to: "Nathaniel Edith").spoken == "nah-THAN-yel EE-dith")
        #expect(!FileManager.default.fileExists(atPath: missingFile.path))
        #expect(!FileManager.default.fileExists(
            atPath: missingFile.deletingLastPathComponent().path))
        #expect(sink.has("\(ViewerWriteGuard.logPrefix) HalliePronunciationLexicon.writeDefault"))
    }

    @Test func viewerFamilyTreeRefreshKeepsPersonAndShippedLayersWithoutCreatingAFile() throws {
        let root = tmp("tree-lexicon")
        defer { try? FileManager.default.removeItem(at: root) }
        let brainRoot = root.appendingPathComponent("brain", isDirectory: true)
        _ = try CyberBrainWriter.setPronunciation(
            subjectName: "Nathaniel Edith", gedcomPersonID: "@I7@",
            token: "Nathaniel", saidAs: "nah-THAN-yel", rootURL: brainRoot)
        PersonPronunciationCache.shared.invalidate()

        let lexiconFile = root.appendingPathComponent(
            "isolated/Hallie/pronunciations.json")
        let defaultsName = "RemoteViewerReadOnlySensorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 SOUR RemoteViewerReadOnlySensorTests
        0 @I7@ INDI
        1 NAME Nathaniel /Edith/
        1 SEX M
        0 TRLR
        """)
        let sink = Sink()
        ViewerModeCenter.shared.reset(sink: { sink.append($0) })
        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        defer { ViewerModeCenter.shared.reset() }

        // `originalsDirectory == nil` deliberately selects the production
        // fallback branch. All writable roots remain isolated test seams.
        let model = FamilyTreeLiveModel(
            compiledStore: FamilyGraphCompiledStore(
                root: root.appendingPathComponent("compiled", isDirectory: true)),
            cyberBrainRootURL: brainRoot,
            pronunciationFileURL: lexiconFile,
            focusDefaults: defaults,
            profilesProvider: { [] })
        model.install(graph: graph)
        model.loadCyberBrainNow()

        let nathaniel = try #require(
            model.selectedPronunciations.first { $0.word == "Nathaniel" })
        let edith = try #require(
            model.selectedPronunciations.first { $0.word == "Edith" })
        #expect(nathaniel.saidAs == "nah-THAN-yel", "CyberBrain person layer survives")
        #expect(nathaniel.effective == "nah-THAN-yel")
        #expect(edith.saidAs == nil)
        #expect(edith.inherited == "EE-dith", "shipped fallback survives")
        #expect(!FileManager.default.fileExists(atPath: lexiconFile.path))
        #expect(!FileManager.default.fileExists(
            atPath: lexiconFile.deletingLastPathComponent().path))
        #expect(sink.has(
            "\(ViewerWriteGuard.logPrefix) HalliePronunciationLexicon.writeDefault"))
    }

    @Test func viewerReturnCannotSubmitPronunciationButPreviewRemainsAvailable() {
        #expect(FamilyTreeView.allowsPronunciationSubmit(viewerMode: false))
        #expect(!FamilyTreeView.allowsPronunciationSubmit(viewerMode: true))
        #expect(FamilyTreeView.allowsPronunciationPreview(viewerMode: false))
        #expect(FamilyTreeView.allowsPronunciationPreview(viewerMode: true))
        #expect(FamilyTreeView.pronunciationPreviewText(
            word: "Latta", draft: "  LAH-tuh  ") == "LAH-tuh")
        #expect(FamilyTreeView.pronunciationPreviewText(
            word: "Latta", draft: "   ") == "Latta")
    }

    /// Master sensor: with the default role, none of the guards fires and
    /// nothing is logged — the master's write paths are untouched.
    @Test func masterModeExecutesGuardedWritersAndLogsNoRefusal() throws {
        let sink = Sink()
        ViewerModeCenter.shared.reset(sink: { sink.append($0) })
        defer { ViewerModeCenter.shared.reset() }
        let root = tmp("master")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ViewerWriteGuard.refuse("probe") == false)
        #expect(throws: Never.self) { try ViewerWriteGuard.check("probe") }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let ged = originals.appendingPathComponent("family.ged")
        try GedcomSyntheticPedigree.gedcom(people: 20, generations: 3)
            .write(to: ged, atomically: true, encoding: .utf8)
        let graph = try #require(GedcomFamilyGraph(fileURL: ged))

        let treeBrain = root.appendingPathComponent("tree-brain", isDirectory: true)
        let tree = FamilyTreeLiveModel(
            originalsDirectory: originals, cyberBrainRootURL: treeBrain)
        tree.install(graph: graph)
        try tree.addNote("Master note", about: tree.selectedID ?? "")
        _ = try tree.recordTestimony(Self.testimony)
        let selectedID = try #require(tree.selectedID)
        let selected = try #require(graph.people[selectedID])
        let selectedWord = try #require(selected.name.split(separator: " ").first.map(String.init))
        try tree.setPronunciation(word: selectedWord, saidAs: "MASTER")
        #expect(FileManager.default.fileExists(
            atPath: treeBrain.appendingPathComponent("cyberbrain.json").path))

        let research = ResearchStore(peopleRoot: root.appendingPathComponent("people"))
        let subject = ResearchSubject(person: selected)
        try research.saveDossier(ResearchDossier(subject: subject))
        try research.cache(.init(
            url: "https://example.test/master", retrievedAt: Date(),
            statusCode: 200, body: Data("master page".utf8)), key: subject.key)
        #expect(try research.loadDossier(key: subject.key) != nil)
        #expect(research.cachedPage(
            key: subject.key, pageURL: "https://example.test/master")?.body
                == Data("master page".utf8))

        try exerciseMasterHallieWriters(root: root)
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

    private func exerciseMasterHallieWriters(root: URL) throws {
        let supportRoot = root.appendingPathComponent("support", isDirectory: true)
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let live = HallieAppTurnCoordinator.Dependencies.makeLive(
            supportRoot,
            HallieLiveAssetStoreFactory {
                FamilyAssetStore(root: assetRoot, cacheRoot: cacheRoot)
            })
        try live.recordTestimony(Self.testimony)
        try live.recordPhotoCaption(.init(
            subjects: [.init(name: "Dad")], speakerName: "Rick",
            text: "Dad at home", photoPath: "/tmp/dad.jpg", date: Date()))
        let manifest = PronunciationDrillManifest(
            version: PronunciationDrillStore.currentVersion,
            generatedAt: Date(), entries: [])
        try live.saveDrillStore(PronunciationDrillStore(), manifest)
        try live.recordPronunciation(.init(
            word: "Sensor", saidAs: "SEN-sor",
            target: .treePerson(name: "Master Sensor", gedcomID: "@M1@", aliases: [])))
        #expect(live.loadLexicon().apply(to: "Edith").spoken == "EE-dith")

        let group = assetRoot.appendingPathComponent(
            "People/MasterSensorFamily", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let photo = group.appendingPathComponent("family.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        try live.excludePhoto(photo, "@M1@", "Rick", "not Dad")

        let hallieRoot = supportRoot.appendingPathComponent("VideoScan", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: hallieRoot.appendingPathComponent("cyberbrain/cyberbrain.json").path))
        #expect(FileManager.default.fileExists(
            atPath: hallieRoot.appendingPathComponent("Hallie/pronunciations.json").path))
        #expect(FileManager.default.fileExists(
            atPath: hallieRoot.appendingPathComponent("Hallie/pronunciation-drill.json").path))
        #expect(FileManager.default.fileExists(
            atPath: photo.appendingPathExtension("notof.json").path))
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

    // MARK: - C04-F5 (P1, 2026-10-06): a viewer Mac must never delete family media

    /// The model flag VideoScanApp sets from CatalogSync (`isReadOnly`)
    /// refuses on its own, for both modes: the file stays on disk and the
    /// record is untouched. (The ViewerModeCenter signal is exercised inside
    /// `everyWritePathRefusesInViewerModeWithALogLine`, which already holds
    /// the process-wide viewer window; a second window here could make
    /// delete tests in parallel suites refuse.)
    @Test func viewerModeRefusesDeleteConfirmedJunkAndLeavesTheFileOnDisk() async throws {
        let root = tmp("junk")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in [VideoScanModel.JunkDeletionMode.toTrash, .permanent] {
            let (model, rec, file) = try Self.junkFixture(in: root)
            model.isReadOnly = true

            let result = await model.deleteConfirmedJunk([rec], mode: mode)

            let label = Comment(rawValue: "mode=\(mode)")
            #expect(FileManager.default.fileExists(atPath: file.path), label)
            #expect(rec.purgedAt == nil, label)
            #expect(rec.lifecycleStage == .cataloged, label)
            #expect(result.succeeded == 0, label)
            #expect(result.refused.map(\.record.id) == [rec.id], label)
        }
    }

    /// One synthetic confirmed-junk file, its record, and a model holding it.
    private static func junkFixture(in root: URL) throws -> (VideoScanModel, VideoRecord, URL) {
        let file = root.appendingPathComponent("test_family_\(UUID().uuidString).mov")
        try Data("family".utf8).write(to: file)
        let rec = VideoRecord()
        rec.fullPath = file.path
        rec.filename = file.lastPathComponent
        rec.directory = root.path
        rec.mediaDisposition = .confirmedJunk
        let model = VideoScanModel()
        model.records = [rec]
        return (model, rec, file)
    }

    /// QA round 1 (C): Triage › Under Construction › Discard trashed files
    /// on a viewer.
    @Test func qaRedViewerModeRefusesDiscardWorkbenchAndLeavesTheFileOnDisk() throws {
        let root = tmp("discard")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, rec, file) = try Self.junkFixture(in: root)
        rec.lifecycleStage = .workbench
        model.isReadOnly = true
        var trashed: [URL] = []

        let n = model.discardWorkbench([rec], trash: { trashed.append($0) })

        #expect(trashed.isEmpty, "nothing may be trashed on a viewer")
        #expect(n == 0)
        #expect(rec.purgedAt == nil)
        #expect(rec.lifecycleStage == .workbench)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Every file in app code that calls trashItem / removeItem, with how
    /// many calls it makes. Media removals name their viewer guard (a token
    /// that must appear in `guardFile`); the rest remove the app's OWN
    /// temp, partial, staging, cache or output files. A new removal call —
    /// anywhere — changes a count and fails here until it is classified.
    private static let removalSites: [String: (count: Int, guardFile: String?, token: String?)] = [
        // Media / family files — behind the viewer guard.
        "MediaOps/VideoScanModel+JunkDelete.swift": (2, nil, "junkDeletionRefusedOnViewer("),
        "Catalog/VideoScanModel+Workbench.swift": (1, nil, "workbenchDiscardRefusedOnViewer("),
        "People/FamilyGroup.swift": (2, nil, "ViewerWriteGuard.check(\"FamilyGroupStore.moveToTrash\")"),
        "People/PersonEditSheet.swift": (1, nil, "ViewerWriteGuard.refuse(\"PersonEditSheet.deleteReferencePhoto\")"),
        // Delete Duplicates' removal step (trash + quarantine removal, and
        // rmdir of its own quarantine folders); reached only from
        // DeleteDuplicatesJob.run, which refuses on a read-only model.
        "MediaOps/SignatureVerification.swift": (4, "MediaOps/DeleteDuplicatesJob.swift", "model.duplicateStatus = \"Deletion unavailable in viewer mode\""),
        // Reached only from MFO jobs (Transcode, Reformat);
        // MediaFileOperationsCenter.add refuses every job on a viewer.
        "MediaOps/DerivativeOutputPublish.swift": (1, "MediaOps/MediaFileOperations.swift", "ViewerWriteGuard.refuse(\"MediaFileOperationsCenter.add("),
        // The app's own temp / partial / staging / cache / output files.
        "App/BundleExporter.swift": (1, nil, nil), "App/BundleImporter.swift": (2, nil, nil),
        "Archive/ArchiveIndexRename.swift": (3, nil, nil),
        "ArchiveAngel/Prepare/ArchiveAngelJob.swift": (1, nil, nil),
        "ArchiveAngel/Prepare/ArchiveAngelPlan.swift": (2, nil, nil),
        "Catalog/CatalogStore.swift": (1, nil, nil), "Catalog/CatalogSync.swift": (3, nil, nil),
        "Catalog/CatalogWriteError.swift": (1, nil, nil),
        "FamilyTree/CouplePortrait.swift": (2, nil, nil), "FamilyTree/FamilyAssetStore.swift": (1, nil, nil),
        "FamilyTree/FamilySearchPullCoordinator.swift": (6, nil, nil),
        "Hallie/HalliePhotoImport.swift": (1, nil, nil), "Hallie/Voice/HallieNeuralSpeech.swift": (7, nil, nil),
        "Hallie/Voice/HalliePronunciationLexicon.swift": (1, nil, nil),
        "Hallie/Web/HallieWebPoster.swift": (3, nil, nil), "Hallie/Web/HallieWebProxy.swift": (3, nil, nil),
        "Media/AudioTranscriber.swift": (1, nil, nil), "Media/CaptionRunner.swift": (2, nil, nil),
        "Media/PerceptualFingerprinter.swift": (1, nil, nil), "Media/ReviewThumbnailRenderer.swift": (1, nil, nil),
        "Media/VideoScanModel+ProbeEngine.swift": (1, nil, nil),
        "MediaOps/BalanceAudioJob.swift": (1, nil, nil), "MediaOps/CleanupJob.swift": (4, nil, nil),
        "MediaOps/FootageSpectrumHelper.swift": (1, nil, nil), "MediaOps/RebuildAudioJob.swift": (1, nil, nil),
        // ReformatJob 5 → 0 (fix/mfo-jobs-n1014): its own partial goes only
        // through PartialFileNaming.remove now.
        "MediaOps/RelocateEngine.swift": (1, nil, nil),
        "MediaOps/TrimJob.swift": (1, nil, nil),
        // unlink of our own partials / published-by-link old names only.
        "MediaOps/RescueFileCopier.swift": (3, nil, nil), "MediaOps/PartialFileNaming.swift": (3, nil, nil), "MediaOps/VideoScanModel+Combine.swift": (1, nil, nil),
        "People/AdaFaceEngine.swift": (1, nil, nil), "People/ArcFaceEngine.swift": (1, nil, nil),
        "People/FamilyEditSheet.swift": (1, nil, nil), "People/FindPersonJob.swift": (1, nil, nil),
        "People/IdentifyFamilyModel.swift": (1, nil, nil), "People/POIProfileFileStore.swift": (2, nil, nil),
        "People/POIStorage.swift": (1, nil, nil), "People/PersonFinderCompilation.swift": (7, nil, nil),
        "People/RecipeGenderAgeGate.swift": (1, nil, nil),
        "Volumes/ScanCheckpoint.swift": (1, nil, nil), "Volumes/ScanJobsStorage.swift": (2, nil, nil),
    ]

    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }

    /// Removal calls per app source file, keyed by path relative to `root`:
    /// FileManager `trashItem(` / `removeItem(`, and the POSIX `unlink(` /
    /// `rmdir(` free functions. Both the root and each file are resolved
    /// through symlinks BEFORE slicing, so a checkout reached as /tmp/… while
    /// the enumerator reports /private/tmp/… (the nightly) still lines up.
    static func removalCounts(under root: URL) throws -> [String: Int] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var found: [String: Int] = [:]
        let it = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base.path + "/") else { continue }
            let rel = String(path.dropFirst(base.path.count + 1))
            let n = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .reduce(0) { $0 + removalCalls(in: String($1)) }
            if n > 0 { found[rel] = n }
        }
        return found
    }

    private static func removalCalls(in line: String) -> Int {
        func occurrences(_ needle: String) -> Int { line.components(separatedBy: needle).count - 1 }
        return occurrences("trashItem(") + occurrences("removeItem(")
            + freeCalls("unlink(", in: line) + freeCalls("rmdir(", in: line)
    }

    /// Calls of a C free function: not `x.unlink(`, not `fooUnlink(`, not
    /// `func unlink(` (MediaPersonLinks has a method of that name).
    private static func freeCalls(_ needle: String, in line: String) -> Int {
        var n = 0
        var search = line.startIndex..<line.endIndex
        while let r = line.range(of: needle, range: search) {
            let prev = r.lowerBound > line.startIndex ? line[line.index(before: r.lowerBound)] : " "
            let isMember = prev.isLetter || prev.isNumber || prev == "_" || prev == "."
            if !isMember && !line[..<r.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix("func") { n += 1 }
            search = r.upperBound..<line.endIndex
        }
        return n
    }

    /// The nightly runs from /private/tmp/nightly-metrics-wt, reached as
    /// /tmp/…: the sensor must give the same answer from a symlinked root.
    @Test func removalSensorGivesTheSameAnswerFromASymlinkedCheckout() throws {
        let dir = tmp("symlinked-checkout")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("test_app_link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.appSourceRoot)
        let direct = try Self.removalCounts(under: Self.appSourceRoot)
        #expect(!direct.isEmpty)
        #expect(try Self.removalCounts(under: link) == direct)
    }

    @Test func everyFileRemovalInAppCodeIsClassifiedAndMediaRemovalsAreViewerGuarded() throws {
        let app = Self.appSourceRoot
        let found = try Self.removalCounts(under: app)
        #expect(found == Self.removalSites.mapValues(\.count),
                "a removal call was added or removed: classify it here (media ⇒ behind the viewer guard)")
        for (file, site) in Self.removalSites {
            guard let token = site.token else { continue }
            let text = try String(contentsOf: app.appendingPathComponent(site.guardFile ?? file), encoding: .utf8)
            #expect(text.contains(token), Comment(rawValue: "\(file): viewer guard `\(token)` missing"))
        }
    }

    /// A viewer must not rewrite the master's scan-target list either
    /// (Volumes → Delete from list…).
    @Test func viewerModeRefusesDeleteFromVolumesList() {
        ViewerModeCenter.shared.reset()
        defer { ViewerModeCenter.shared.reset() }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/test_viewer_volume_\(UUID().uuidString)")
        model.scanTargets = [target]
        model.isReadOnly = true
        #expect(model.deleteScanTarget(target) == false)
        #expect(model.scanTargets.contains { $0 === target }, "the list is unchanged on a viewer")
    }

    /// Source sensor: the read-only refusal is the FIRST thing
    /// `deleteConfirmedJunk` does, so every caller (row menu, toolbar and
    /// Triage sheets, Cmd-Delete, prune) sits behind it, and a new caller
    /// is named here so it gets reviewed.
    @Test func everyCallerOfDeleteConfirmedJunkSitsBehindTheViewerGuard() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
        let defFile = app.appendingPathComponent("MediaOps/VideoScanModel+JunkDelete.swift")
        let def = try String(contentsOf: defFile, encoding: .utf8)
        /// First non-comment statement after `opener`, searched from `sig`.
        func firstStatement(after sig: String, opener: String) throws -> String? {
            let s = try #require(def.range(of: sig))
            let body = try #require(def.range(of: opener, range: s.upperBound..<def.endIndex))
            return def[body.upperBound...].split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("//") }
        }
        let entry = try firstStatement(after: "func deleteConfirmedJunk(",
                                       opener: ") async -> JunkDeletionResult {")
        #expect(entry?.hasPrefix("let (records, finished) = junkDeletionPreflight(") == true,
                "deleteConfirmedJunk must start with the preflight; found \(entry ?? "nil")")
        let preflight = try firstStatement(after: "func junkDeletionPreflight(",
                                           opener: "finished: JunkDeletionResult?) {")
        #expect(preflight?.hasPrefix("if let refused = junkDeletionRefusedOnViewer(") == true,
                "the viewer refusal must be the preflight's first statement; found \(preflight ?? "nil")")

        var callers: Set<String> = []
        let it = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("func "),
                      t.contains("deleteConfirmedJunk(") else { continue }
                callers.insert(url.lastPathComponent)
            }
        }
        #expect(callers == ["CatalogRowContextMenu.swift", "VideoScanModel+TrashSelection.swift",
                            "VideoScanModel+PruneApply.swift", "VideoScanModel+JunkTrashSnapshot.swift"],
                "a new deleteConfirmedJunk caller: confirm it relies on the model's viewer guard, then add it here")
    }
}
