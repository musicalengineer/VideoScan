// PersonFinderLiveCatalogPrefilterTests.swift
// Bug (2026-10-21): the Person Finder catalog prefilter (issue #66) decoded
// the frozen catalog.json at every job start — inside MainActor.run — via
// `CatalogStore.readRecordsWithoutAdopting()`. Since the 10/18 cutover
// catalog.sqlite is the authority and catalog.json is frozen, so the
// unscannable / already-known / junk / too-short / low-res decisions were
// made on pre-cutover data. The fix reads the LIVE records the catalog model
// holds (`VideoScanModel.personScanSkipFacts` → `pfLiveCatalogSkipResult`).
//
// This file holds the cases that need a filesystem sandbox (a SQLite-
// authority CutoverScene, or a temp folder of video files for the job path).
// The pure logic, the 100k scale case and the wiring sensor are in
// PersonFinderLiveCatalogPrefilterUnitTests.swift (gauntlet-selectable).
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      a record that exists ONLY in the live (SQLite-loaded) records
//              drives every skip category, under a real SQLite-authority
//              sandbox (CutoverScene.launchOnSQLite); a removed record stops
//              being skipped; the job path always writes one prefilter line
//              with the record count — including N == 0 (early launch).
//   ISOLATION  a poisoned catalog.json (a ghost audio-only file, a live file
//              falsely marked unscannable + junk) has no effect.
//   MEDIA      N/A — no media is decoded (the job-path case uses empty .mov
//              files only for discovery by extension).
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
        #expect(result.checkedRecords == model.records.filter { !$0.fullPath.isEmpty }.count)
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
}

// MARK: - The job path's prefilter line (never silent)

@Suite("Person Finder prefilter — the job log always says what it checked", .serialized)
@MainActor
struct PersonFinderPrefilterJobLogTests {

    /// A temp folder holding `names` as empty files (discovery is by
    /// extension; nothing is decoded).
    private func folder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pf_prefilter_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in names.enumerated() {
            // Distinct sizes: discovery de-dupes on name + size.
            try Data(repeating: 0, count: i + 1).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func discover(in dir: URL, catalog: PFLiveCatalogSource) async -> (files: [String]?, log: [String]) {
        let job = ScanJob(searchPath: dir.path)
        var settings = PersonFinderSettings()
        settings.skipCatalogBadFiles = true
        let files = await PersonFinderModel.discoverVideos(job: job, settings: settings, liveCatalog: catalog)
        job.flushConsoleLines()
        return (files, job.consoleLines)
    }

    @Test("N == 0: an early-launch job says the catalog has no records loaded yet")
    func emptyCatalogExplainsItself() async throws {
        let dir = try folder(["a.mov", "b.mov"]); defer { try? FileManager.default.removeItem(at: dir) }
        let (files, log) = await discover(in: dir, catalog: PFLiveCatalogSource { [] })
        #expect(files?.count == 2, "nothing is skipped")
        #expect(log.contains("Catalog prefilter: the catalog has no records loaded yet — nothing skipped"),
                "log: \(log)")
    }

    @Test("N > 0: one line with the record count and the skip count, then the existing breakdown")
    func countedLine() async throws {
        let dir = try folder(["a.mov", "b.mov"]); defer { try? FileManager.default.removeItem(at: dir) }
        let aPath = dir.appendingPathComponent("a.mov").path
        let catalog = PFLiveCatalogSource {
            [PFSkipFacts(fullPath: aPath, isUnscannable: true),
             PFSkipFacts(fullPath: "/Volumes/Elsewhere/c.mov"),
             PFSkipFacts(fullPath: "/Volumes/Elsewhere/d.mov")]
        }
        let (files, log) = await discover(in: dir, catalog: catalog)
        #expect(files == [dir.appendingPathComponent("b.mov").path])
        #expect(log.contains("Catalog prefilter: checked 3 catalog record(s), skipped 1 file(s)"), "log: \(log)")
        #expect(log.contains("Catalog prefilter skipped 1 file(s) (1 unscannable)"), "log: \(log)")
    }

    @Test("no catalog connected: the job says so")
    func notConnectedSaysSo() async throws {
        let dir = try folder(["a.mov"]); defer { try? FileManager.default.removeItem(at: dir) }
        let (files, log) = await discover(in: dir, catalog: PFLiveCatalogSource(nil))
        #expect(files?.count == 1)
        #expect(log.contains("Catalog prefilter: no catalog connected — nothing skipped"), "log: \(log)")
    }
}
