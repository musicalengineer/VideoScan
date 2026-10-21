// PersonFinderLiveCatalogPrefilterTests.swift
// Bug (2026-10-21): the Person Finder catalog prefilter (issue #66) decoded
// the frozen catalog.json at every job start — inside MainActor.run — via
// `CatalogStore.readRecordsWithoutAdopting()`. Since the 10/18 cutover
// catalog.sqlite is the authority and catalog.json is frozen, so the
// unscannable / already-known / junk / too-short / low-res decisions were
// made on pre-cutover data. The fix reads the LIVE records the catalog model
// holds (`VideoScanModel.personScanSkipFacts` → `pfLiveCatalogSkipResult`).
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      a record that exists ONLY in the live (SQLite-loaded) records
//              drives every skip category, under a real SQLite-authority
//              sandbox (CutoverScene.launchOnSQLite); the value snapshot
//              gives the same result as the record rules; no catalog
//              connected → nil (the job says so), never a file read.
//   ISOLATION  a poisoned catalog.json (a ghost audio-only file, a live file
//              falsely marked unscannable + junk) has no effect.
//   SCALE      100k synthetic records: snapshot + skip set within a budget.
//   SENSOR     the job path passes the live source through; ContentView
//              wires it (source pins).
//   MEDIA      N/A — no media is opened.
// Red evidence: the LOGIC case against the old store-read path failed with
// `result.unscannable.contains(live.fullPath)` false (Debug, 2026-10-21).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func record(_ path: String, stream: StreamType = .videoAndAudio,
                    detected: [String] = [], junk: Int = 0,
                    duration: Double = 60, resolution: String = "1920x1080") -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.streamTypeRaw = stream.rawValue
    r.detectedPeople = detected
    r.junkScore = junk
    r.durationSeconds = duration
    r.resolution = resolution
    return r
}

@Suite("Person Finder prefilter reads the LIVE catalog, never the frozen catalog.json", .serialized)
@MainActor
struct PersonFinderLiveCatalogPrefilterTests {

    @Test("LOGIC: under the SQLite authority a record only in the live records drives the skip set")
    func liveOnlyRecordDrivesSkipSet() async throws {
        let scene = try CutoverScene.make("pf_live"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)

        let base = "/Volumes/TestVol/after_cutover"
        let fresh = [
            record("\(base)/audio.wav", stream: .audioOnly),
            record("\(base)/donna.mov", detected: ["Donna"]),
            record("\(base)/junk.mov", junk: 95),
            record("\(base)/short.mov", duration: 2),
            record("\(base)/tiny.mov", resolution: "320x240"),
        ]
        scene.model.records.append(contentsOf: fresh)
        let json = try String(contentsOf: scene.catalogURL, encoding: .utf8)
        #expect(!json.contains("after_cutover"), "the fresh records must exist ONLY in the live catalog")

        let model = scene.model
        let result = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: "donna", source: { model.personScanSkipFacts() }))
        #expect(result.unscannable.contains("\(base)/audio.wav"))
        #expect(result.alreadyKnown.contains("\(base)/donna.mov"))
        #expect(result.junkScored.contains("\(base)/junk.mov"))
        #expect(result.tooShort.contains("\(base)/short.mov"))
        #expect(result.lowResolution.contains("\(base)/tiny.mov"))
        // Same rules as before the fix: the whole result equals the record
        // rules applied to the live records.
        #expect(result == pfPersonScanSkipPaths(from: model.records, targetPersonName: "donna"))
    }

    @Test("LOGIC: a record removed from the live catalog is no longer skipped")
    func removedRecordNotSkipped() async throws {
        let scene = try CutoverScene.make("pf_removed"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        model.records.append(record("/Volumes/TestVol/gone.wav", stream: .audioOnly))
        let before = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: nil, source: { model.personScanSkipFacts() }))
        #expect(before.unscannable.contains("/Volumes/TestVol/gone.wav"))
        model.records.removeAll { $0.fullPath == "/Volumes/TestVol/gone.wav" }
        let after = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: nil, source: { model.personScanSkipFacts() }))
        #expect(!after.all.contains("/Volumes/TestVol/gone.wav"))
    }

    @Test("ISOLATION: a poisoned catalog.json in the sandbox has no effect")
    func poisonedJSONHasNoEffect() async throws {
        let scene = try CutoverScene.make("pf_poison"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let liveVideo = record("/Volumes/TestVol/live_good.mov")
        model.records.append(liveVideo)
        let honest = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: "donna", source: { model.personScanSkipFacts() }))

        // Poison: a catalog.json written by a scratch store, claiming a ghost
        // audio-only file and that the live good video is unscannable junk
        // Donna is already known in — then laid over the sandbox's file.
        let scratch = scene.folder.deletingLastPathComponent()
            .appendingPathComponent("poison_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let poisonStore = CatalogStore(directory: scratch)
        let poisoned = [
            record("/Volumes/PoisonVol/ghost.wav", stream: .audioOnly),
            record(liveVideo.fullPath, stream: .ffprobeFailed, detected: ["Donna"], junk: 100,
                   duration: 1, resolution: "160x120"),
        ]
        try #require(poisonStore.saveNow(records: poisoned))
        try FileManager.default.removeItem(at: scene.catalogURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: poisonStore.fileLocation),
                                         to: scene.catalogURL)
        let json = try String(contentsOf: scene.catalogURL, encoding: .utf8)
        try #require(json.contains("ghost.wav"), "the poison must actually be on disk")

        let result = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: "donna", source: { model.personScanSkipFacts() }))
        #expect(result == honest)
        #expect(!result.all.contains("/Volumes/PoisonVol/ghost.wav"))
        #expect(!result.all.contains(liveVideo.fullPath))
    }

    @Test("LOGIC: no catalog connected → nil (the job says so), not an empty catalog")
    func noSourceIsNil() async {
        #expect(await pfLiveCatalogSkipResult(targetPersonName: "donna", source: nil) == nil)
        #expect(await pfLiveCatalogSkipResult(targetPersonName: "donna", source: { [] })
                == CatalogSkipResult())
        #expect(await PFLiveCatalogSource(nil).skipResult(targetPersonName: "donna") == nil)
        let one = PFLiveCatalogSource { [PFSkipFacts(fullPath: "/v/a.wav", isUnscannable: true)] }
        #expect(await one.skipResult(targetPersonName: nil)?.unscannable == ["/v/a.wav"])
    }

    @Test("LOGIC: the value snapshot keeps every rule's input (records without a path dropped)")
    func snapshotFaithful() {
        let r = record("/v/a.mov", stream: .videoOnly, detected: ["Donna"], junk: 7,
                       duration: 3.5, resolution: "640x480")
        r.suspectedPeople = ["Hallie"]
        let unnamed = record("")
        let facts = pfSkipFacts(from: [r, unnamed])
        #expect(facts == [PFSkipFacts(fullPath: "/v/a.mov", isUnscannable: false,
                                      detectedPeople: ["Donna"], suspectedPeople: ["Hallie"],
                                      junkScore: 7, durationSeconds: 3.5, resolution: "640x480")])
        for stream in [StreamType.audioOnly, .noStreams, .ffprobeFailed] {
            #expect(PFSkipFacts(record("/v/x", stream: stream)).isUnscannable)
        }
        for stream in [StreamType.videoAndAudio, .videoOnly] {
            #expect(!PFSkipFacts(record("/v/x", stream: stream)).isUnscannable)
        }
    }
}

@Suite("Person Finder live prefilter — scale (100k records)")
@MainActor
struct PersonFinderLiveCatalogPrefilterScaleTests {

    @Test("SCALE: 100k synthetic records snapshot + skip set within budget")
    func hundredThousand() async throws {
        let n = 100_000
        var recs: [VideoRecord] = []
        recs.reserveCapacity(n)
        for i in 0..<n {
            switch i % 5 {
            case 0: recs.append(record("/Volumes/S/\(i).wav", stream: .audioOnly))
            case 1: recs.append(record("/Volumes/S/\(i).mov", detected: ["Donna"]))
            case 2: recs.append(record("/Volumes/S/\(i).mov", duration: 1))
            case 3: recs.append(record("/Volumes/S/\(i).mov", resolution: "320x240"))
            default: recs.append(record("/Volumes/S/\(i).mov"))
            }
        }
        let catalog = recs
        let start = ContinuousClock.now
        let result = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: "donna", source: { pfSkipFacts(from: catalog) }))
        let elapsed = ContinuousClock.now - start
        #expect(result.unscannable.count == n / 5)
        #expect(result.alreadyKnown.count == n / 5)
        #expect(result.tooShort.count == n / 5)
        #expect(result.lowResolution.count == n / 5)
        #expect(result.all.count == 4 * n / 5)
        // Budget: Debug build on the M4/M1 measures well under this; the old
        // path decoded ~80 MB of JSON on the main actor at every job start.
        #expect(elapsed < .seconds(5), "100k prefilter took \(elapsed)")
        print("PF live prefilter 100k: \(elapsed)")
    }
}

@Suite("Person Finder live prefilter — sensor (source wiring)")
struct PersonFinderLiveCatalogPrefilterSensor {

    @Test("SENSOR: the job path passes the live source to the prefilter; ContentView wires it")
    func wiring() throws {
        let lifecycle = try SourceTree.appSource(named: "PersonFinderModel+JobLifecycle.swift")
        #expect(lifecycle.contains("let liveCatalog = PFLiveCatalogSource(self.catalogSkipFactsSource)"))
        #expect(lifecycle.contains("liveCatalog: liveCatalog"))
        #expect(lifecycle.contains("await liveCatalog.skipResult(targetPersonName: targetName)"))
        #expect(!lifecycle.contains("pfPersonScanSkipResult("))
        let content = try SourceTree.appSource(named: "ContentView.swift")
        #expect(content.contains("personFinderModel.catalogSkipFactsSource = { [weak model] in"))
        #expect(content.contains("model?.personScanSkipFacts() ?? []"))
    }
}
