// ProvenanceFieldsAppTests.swift — the three provenance fields Rick types
// (digitization date, tape, source) and the new-media notice, in the app
// (ProvenanceFieldsStore, NewMediaProvenanceStore, the views' pure rules;
// DECISIONS 2026-11-27; the field rule and the new-media decision themselves
// are Core's ProvenanceFieldsTests).
//
// Dimensions (CLAUDE.md rule 8, a catalog writer that shows facts):
//   STORE      save lands Rick's rows through the one door and reads them back;
//              a change is corrected, a clear rejected; unchanged writes
//              nothing; every case relaunched (a NEW model).
//   TRUTH      a missing field reads "unknown"; the Inspector's lines come from
//              catalog.sqlite and only for the content they were read for.
//   ARCHIVED   rule 3: a digitization date on archived content is REFUSED and
//              the whole save rolls back (nothing written); tape and source
//              alone land.
//   WRITER     a save inside the 2 s debounce window of a record edit; during a
//              job's write hold (REFUSED, nothing written, lands after
//              release); across a role flip master → viewer → master; relaunch.
//   SEARCH     "digitized 2024", the tape label and the source text find the
//              file in the Catalog search; beside the era layer, both find.
//   NEW MEDIA  scan pipeline: new vs re-seen vs moved; Fill In Full Hashes
//              (the real job) offers only content the catalog never saw;
//              never shown for zero (a scan with no new media, a copy of known
//              content); not repeated; remembered across a relaunch; Skip.
//   ISOLATION  an unattached store refuses with words and shows unknown; a
//              file with no full SHA-256 is refused; an unreadable queue file
//              starts empty.
//   SCALE      100k records → the new-media evaluation and the search join
//              inside a budget.
//   SENSOR     no SQL / commit in the views; no `extension VideoScanModel` in
//              the new files; the merge registers strangers; Full Hashes
//              evaluates after its save; the flip attaches the stores.
//
// Suites (filter by SUITE): ProvenanceFieldsStoreAppTests · ProvenanceFieldsSearchAppTests ·
// NewMediaProvenanceAppTests · NewMediaProvenanceScaleAppTests · ProvenanceFieldsSensorAppTests ·
// ProvenanceFieldsRound2AppTests (Codex round 2: one carrier reading for every reader; history rows
// out of search; resumed Full Hashes; notice ids across a rescan; new bytes at a known path; load vs save)
// Synthetic names only.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let savedAt = Date(timeIntervalSince1970: 1_795_000_000)     // 2026-11-17

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

@MainActor
private func launch(_ scene: CutoverScene) async throws -> (healthy: String, other: String) {
    try await scene.launchOnSQLite()
    try #require(scene.model.catalogCutover.isSQLiteAuthority, "the scene launched on catalog.sqlite")
    #expect(await scene.model.provenanceFields.load() == nil)
    return (try #require(CatalogCommit.digest(of: try scene.record(.healthy))),
            try #require(CatalogCommit.digest(of: try scene.record(.stalePrint))))
}

/// Quit and launch again: a NEW model on the same folder.
@MainActor
private func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
    if let committer = model.catalogCutover.committer { await committer.repository.close() }
    let sandbox = scene.sandbox
    let fresh = VideoScanModel(logDirectory: sandbox.logs)
    fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
    fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
    fresh.records = fresh.loadCatalogAtLaunch()
    try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
    #expect(await fresh.provenanceFields.load() == nil)
    return fresh
}

@MainActor
private func rows(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.ProvenanceAssertionReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: digest) }
}

@MainActor
private func rowCount(_ model: VideoScanModel) async throws -> Int {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertionCount() }
}

private let typed = ProvenanceFieldValues(digitizedOn: "2024-07-04", carrier: "Hi8 Cape tape 3", source: "Uncle's attic box")

// MARK: - STORE · TRUTH · ARCHIVED · WRITER (catalog.sqlite)

@Suite("Provenance fields — the store and the writer cases on catalog.sqlite")
@MainActor
struct ProvenanceFieldsStoreAppTests {

    @Test("save lands Rick's three rows through the door, reads back, survives a relaunch; a change is corrected, a clear rejected")
    func saveRoundTripAndRelaunch() async throws {
        let scene = try CutoverScene.make("pf_roundtrip"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceFields
        #expect(await store.readCurrent(digest: ids.healthy) == .values(digest: ids.healthy, ProvenanceFieldValues()))
        #expect(store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .saved(changed: 3))
        let stored = try await rows(scene.model, ids.healthy)
        #expect(stored.map(\.field) == ["digitizedOn", "carrier", "source"])
        #expect(stored.allSatisfy { $0.state == "confirmed" && $0.by == "rick" && $0.confidence == nil })
        #expect(stored.allSatisfy { $0.evidenceJSON.contains("review list") })
        #expect(store.values(of: ids.healthy) == typed)
        #expect(store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .unchanged)
        #expect(try await rowCount(scene.model) == 3, "an unchanged save writes nothing")
        let changed = ProvenanceFieldValues(digitizedOn: "2024-08", carrier: nil, source: "Uncle's attic box")
        #expect(store.save(digest: ids.healthy, typed: changed, enteredIn: "inspector", now: savedAt.addingTimeInterval(60)) == .saved(changed: 2))
        #expect(try await rows(scene.model, ids.healthy).suffix(2).map(\.state) == ["corrected", "rejected"])
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Provenance: START save provenance fields for content \(ids.healthy.prefix(12))… (review list)"), "\(log.suffix(900))")
        #expect(log.contains("Provenance: OUTCOME save provenance fields for content \(ids.healthy.prefix(12))… — Digitized set, Tape set, Source set."))
        #expect(log.contains("via provenance fields"), "the committer's own OUTCOME line names the table")
        #expect(!log.contains("Hi8 Cape tape 3"), "typed values are not logged")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceFields.values(of: ids.healthy) == changed)
        #expect(await fresh.provenanceFields.readCurrent(digest: ids.healthy) == .values(digest: ids.healthy, changed))
        #expect(fresh.provenanceFields.values(of: ids.other).isEmpty)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("TRUTH: a missing field reads unknown; the Inspector's lines are for the content they were read for, never another")
    func inspectorTruth() async throws {
        let scene = try CutoverScene.make("pf_truth"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceFields
        _ = store.save(digest: ids.healthy, typed: ProvenanceFieldValues(carrier: "Tape 1"), enteredIn: "review list", now: savedAt)
        let reading = await store.readCurrent(digest: ids.healthy.uppercased())
        #expect(InspectorProvenanceFieldsLines.lines(digest: ids.healthy, reading: reading)
                == ["Digitized: unknown", "Tape: Tape 1", "Source: unknown"])
        #expect(InspectorProvenanceFieldsLines.lines(digest: ids.other, reading: reading) == ["Digitized: …", "Tape: …", "Source: …"],
                "a reading for another content is never shown")
        #expect(InspectorProvenanceFieldsLines.lines(digest: nil, reading: reading) == [ProvenanceFieldsWords.inspectorNoDigest])
        let other = await store.readCurrent(digest: ids.other)
        #expect(InspectorProvenanceFieldsLines.lines(digest: ids.other, reading: other) == ["Digitized: unknown", "Tape: unknown", "Source: unknown"])
    }

    @Test("ARCHIVED (rule 3): a digitization date on archived content is REFUSED and nothing is written; tape and source alone land")
    func archivedContentKeepsItsDate() async throws {
        let scene = try CutoverScene.make("pf_archived"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let healthy = try scene.record(.healthy)
        healthy.lifecycleStage = .archived
        #expect(scene.model.saveCatalogNow(), "the archived stage is in catalog.sqlite")
        let store = scene.model.provenanceFields
        guard case .refused(let words) = store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) else {
            Issue.record("expected a refusal"); return
        }
        #expect(words.contains(ProvenanceFieldsWords.archivedDate), "\(words)")
        #expect(try await rowCount(scene.model) == 0, "the whole save rolled back — not even tape and source")
        #expect(store.values(of: ids.healthy).isEmpty)
        #expect(scene.sandbox.catalogLogText().contains("Provenance: REFUSED save provenance fields for content \(ids.healthy.prefix(12))…"))
        let metadataOnly = ProvenanceFieldValues(carrier: "Tape 1", source: "attic")
        #expect(store.save(digest: ids.healthy, typed: metadataOnly, enteredIn: "review list", now: savedAt) == .saved(changed: 2))
        #expect(await store.readCurrent(digest: ids.healthy) == .values(digest: ids.healthy, metadataOnly))
        #expect(scene.model.isDateReadOnly(healthy), "the form greys the date out for this file")
    }

    @Test("ISOLATION: an unattached store refuses with words and shows unknown; a file with no full SHA-256 is refused")
    func isolation() async throws {
        let store = ProvenanceFieldsStore()
        guard case .refused(let words) = store.save(digest: hex(1), typed: typed, enteredIn: "x") else { Issue.record("expected a refusal"); return }
        #expect(words.contains("not open"))
        #expect(store.values(of: hex(1)).isEmpty)
        #expect(await store.readCurrent(digest: hex(1)) == .unavailable(digest: hex(1), why: "the catalog is not open"))
        #expect(store.save(digest: "not-a-digest", typed: typed, enteredIn: "x") == .refused(ProvenanceFieldsWords.noDigest))
        #expect(store.writeRefusal != nil)
    }

    @Test("WRITER: a save inside the 2 s debounce window of a record edit — both land, both survive the relaunch")
    func insideTheDebounceWindow() async throws {
        let scene = try CutoverScene.make("pf_debounce"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let healthy = try scene.record(.healthy)
        healthy.userNotes = "typed just before the provenance"
        scene.model.saveCatalogDebounced()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the edit is waiting on the debounce timer")
        #expect(scene.model.provenanceFields.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .saved(changed: 3))
        #expect(committer.blockedReason == nil, "the side-table commit did not block the record commit")
        #expect(scene.model.saveCatalogNow(), "the edit inside the window still commits")
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceFields.values(of: ids.healthy) == typed)
        #expect(fresh.records.first { $0.id == healthy.id }?.userNotes == "typed just before the provenance")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: during a job's write hold the save is REFUSED with the hold's words and nothing is written; after release it lands and survives the relaunch")
    func duringAWriteHold() async throws {
        let scene = try CutoverScene.make("pf_hold"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceFields
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        guard case .refused(let words) = store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) else {
            Issue.record("expected a refusal"); return
        }
        #expect(words.contains("held — a test job"))
        #expect(store.writeRefusal != nil)
        #expect(try await rowCount(scene.model) == 0, "nothing written")
        #expect(store.values(of: ids.healthy).isEmpty, "a refused save never shows as saved")
        scene.model.catalogStore.releaseWriteHold()
        #expect(store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .saved(changed: 3))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceFields.values(of: ids.healthy) == typed)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: across a role flip — the viewer is refused in words (nothing written), master again saves; the relaunch shows the master's value")
    func acrossAViewerMasterFlip() async throws {
        let scene = try CutoverScene.make("pf_flip"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceFields
        #expect(store.save(digest: ids.healthy, typed: ProvenanceFieldValues(carrier: "Tape 1"), enteredIn: "review list", now: savedAt) == .saved(changed: 1))
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        guard case .refused(let words) = store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) else {
            Issue.record("expected a refusal"); return
        }
        #expect(words.contains("viewer"))
        #expect(try await rowCount(scene.model) == 1, "the viewer wrote nothing")
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(store.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .saved(changed: 3),
                "digitized and source set, the tape corrected")
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceFields.values(of: ids.healthy) == typed)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("the estimate's carrier and Rick's tape share the field: his typed label stands over the machine's VHS, and Confirm Provenance writes back what is shown")
    func sharedCarrierField() async throws {
        let scene = try CutoverScene.make("pf_carrier"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let machine = ["role": "master", "carrier": "VHS"].sorted { $0.key > $1.key }.map { field, value in
            CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: ids.healthy, field: field, value: value,
                                                state: "inferred", by: ProvenanceEstimateRule.signer, at: 1,
                                                confidence: 0.9, evidenceJSON: "{}")
        }
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.commitSideTables("seed a machine estimate", via: .provenanceEstimates) { tx in
            for draft in machine { _ = try tx.appendProvenanceAssertion(draft) }
        } == nil)
        #expect(await scene.model.provenanceFields.readCurrent(digest: ids.healthy) == .values(digest: ids.healthy, ProvenanceFieldValues()),
                "the machine's VHS is never shown as Rick's tape")
        _ = scene.model.provenanceFields.save(digest: ids.healthy, typed: ProvenanceFieldValues(carrier: "Cape 1994"), enteredIn: "review list", now: savedAt)
        let all = try await rows(scene.model, ids.healthy)
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: all)?.carrier == "Cape 1994", "Rick's decision wins in the estimate's reading too")
        #expect(ProvenanceResolver.estimate(fromRowsOfOneSubject: all)?.isConfirmed == false, "the role itself is still only estimated")
    }
}

// MARK: - SEARCH

@Suite("Provenance fields — Catalog search")
@MainActor
struct ProvenanceFieldsSearchAppTests {

    @Test("the digitization year, the tape label and the source text find the file; a file without them does not match")
    func searchHits() async throws {
        let scene = try CutoverScene.make("pf_search"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let model = scene.model
        model.searchIndex.rebuild(records: model.records)
        #expect(model.provenanceFields.save(digest: ids.healthy, typed: typed, enteredIn: "review list", now: savedAt) == .saved(changed: 3))
        let healthy = try scene.record(.healthy)
        for query in ["digitized 2024", "Hi8", "\"Cape tape 3\"", "attic", "source uncle"] {
            let hits = model.searchIndex.filter(records: model.records, query: query)
            #expect(hits.contains { $0 === healthy }, "\(query)")
            #expect(!hits.contains { $0 === (try? scene.record(.stalePrint)) }, "\(query) matched a file without provenance")
        }
        #expect(model.searchIndex.filter(records: model.records, query: "digitized 2023").isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "digitizedOn").isEmpty, "never the field key")

        // A relaunch: the store's load feeds the index again.
        let fresh = try await relaunch(scene, from: model)
        fresh.searchIndex.rebuild(records: fresh.records)
        fresh.provenanceFields.publishSearch()
        #expect(fresh.searchIndex.filter(records: fresh.records, query: "Hi8").contains { $0.id == healthy.id })
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("beside the era layer: each source replaces only its own words; both find the same path; a removed path leaves both")
    func twoLayers() {
        let index = CatalogSearchIndex()
        let r = VideoRecord()
        r.fullPath = "/V/test_clip.mov"
        r.filename = "test_clip.mov"
        index.rebuild(records: [r])
        index.setObservations([r.fullPath: .init(words: ["1990s", "90s"], years: 1990...1995)])
        index.setObservations([r.fullPath: .init(words: ["digitized 2024", "tape Cape"], years: nil)], source: .provenance)
        #expect(index.filter(records: [r], query: "90s").count == 1)
        #expect(index.filter(records: [r], query: "decade:1990s").count == 1, "the era's years still match")
        #expect(index.filter(records: [r], query: "digitized cape").count == 1)
        #expect(index.filter(records: [r], query: "year:2024").isEmpty, "a digitization year is a word, never a filming year")
        index.setObservations([:], source: .provenance)
        #expect(index.filter(records: [r], query: "cape").isEmpty)
        #expect(index.filter(records: [r], query: "90s").count == 1, "clearing provenance leaves the era alone")
        index.setObservations([r.fullPath: .init(words: ["tape Cape"], years: nil)], source: .provenance)
        index.remove(fullPath: r.fullPath)
        index.setObservations([:])
        #expect(index.observationTerms(forPath: r.fullPath) == nil, "a removed path does not come back from another layer")
    }
}

// MARK: - NEW MEDIA

private func makeTempDir(_ label: String) throws -> URL {
    var dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vs_newmedia_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}

private func bytes(_ index: Int) -> Data { Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &+ index &* 31) }) }

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor
private func pipelineModel() -> VideoScanModel {
    let model = VideoScanModel()
    var opts = ScanOptions()
    opts.skipSmallFiles = false
    opts.skipChecksums = false
    opts.probeExtensionless = false
    model.scanOptions = opts
    return model
}

@MainActor
private func scan(_ model: VideoScanModel, _ dir: URL, previous: [CatalogScanTarget]) async -> [CatalogScanTarget] {
    let target = CatalogScanTarget(searchPath: dir.path)
    model.scanTargets = previous + [target]
    model.startTarget(target)
    _ = await target.scanTask?.value
    return previous + [target]
}

/// What Fill In Full Hashes stores: the file's own SHA-256 on its record.
@MainActor
private func hashAll(_ model: VideoScanModel) {
    for rec in model.records where rec.contentFixity == nil {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rec.fullPath)) else { continue }
        // The file's REAL stamp, hashed NOW (as the job records it): an unchanged file keeps its hash across a rescan.
        rec.contentFixity = ContentFixity(digest: sha(data), byteCount: Int64(data.count),
                                          stamp: FileIdentityStamp.capture(path: rec.fullPath)
                                              ?? FileIdentityStamp(device: 1, inode: 1, size: Int64(data.count), mtimeNs: 1),
                                          computedAt: Date().addingTimeInterval(2))
    }
}

@Suite("New media — the notice after Fill In Full Hashes")
@MainActor
struct NewMediaProvenanceAppTests {

    @Test("LOGIC (scan pipeline): new files wait; a re-seen file and a moved file are not new; after the hashes ONE notice counts only new content")
    func newVersusReseenVersusMoved() async throws {
        let dir = try makeTempDir("pipeline"); defer { try? FileManager.default.removeItem(at: dir) }
        try bytes(1).write(to: dir.appendingPathComponent("test_a.mov"))
        try bytes(2).write(to: dir.appendingPathComponent("test_b.mov"))
        let model = pipelineModel()
        let store = model.newMediaProvenance
        var targets = await scan(model, dir, previous: [])
        #expect(store.pending.count == 2, "the first scan of a folder brings two files in")
        hashAll(model)
        #expect(store.evaluate(records: model.records).newContents.count == 2)
        #expect(store.notice?.count == 2)
        #expect(store.notice?.text == "2 new media files came into the catalog — review their provenance when you can.")
        store.skip()
        #expect(store.notice == nil)

        // Rename a (moved), keep b (re-seen), add c (new): only c waits.
        try FileManager.default.moveItem(at: dir.appendingPathComponent("test_a.mov"), to: dir.appendingPathComponent("test_a_renamed.mov"))
        try bytes(3).write(to: dir.appendingPathComponent("test_c.mov"))
        targets = await scan(model, dir, previous: targets)
        let c = try #require(model.records.first { $0.filename == "test_c.mov" })
        #expect(store.pending == [c.id], "re-seen and moved files are not strangers")
        hashAll(model)
        store.evaluate(records: model.records)
        #expect(store.notice?.count == 1)
        #expect(store.notice?.text == "1 new media file came into the catalog — review its provenance when you can.")
        #expect(store.notice?.contents.first?.recordIDs == [c.id])
        #expect(store.pending.isEmpty)

        // NOT SHOWN for a scan with no new media: a rescan re-sees everything.
        // (A re-seen file whose stored hash its stamp no longer vouches for —
        // the rename moved test_a's ctime — waits for its hash and then
        // settles quietly by digest: Codex round 2, digest novelty, not path.)
        store.skip()
        _ = await scan(model, dir, previous: targets)
        let renamed = try #require(model.records.first { $0.filename == "test_a_renamed.mov" && $0.removal == nil })
        #expect(store.pending.isSubset(of: [renamed.id]), "only a file whose hash must be taken again may wait")
        hashAll(model)
        store.evaluate(records: model.records)
        #expect(store.notice == nil, "no notice for zero new files")
        #expect(store.pending.isEmpty)
    }

    @Test("a re-seen file that was still waiting keeps waiting under its fresh record")
    func waitingFileFollowsTheRescan() async throws {
        let dir = try makeTempDir("follow"); defer { try? FileManager.default.removeItem(at: dir) }
        try bytes(4).write(to: dir.appendingPathComponent("test_d.mov"))
        let model = pipelineModel()
        let targets = await scan(model, dir, previous: [])
        let first = try #require(model.records.first)
        #expect(model.newMediaProvenance.pending == [first.id])
        _ = await scan(model, dir, previous: targets)
        let fresh = try #require(model.records.first { $0.filename == "test_d.mov" })
        #expect(model.newMediaProvenance.pending == [fresh.id], "still waiting, under the record that is in the catalog now")
        hashAll(model)
        #expect(model.newMediaProvenance.evaluate(records: model.records).newContents.count == 1)
    }

    @Test("Fill In Full Hashes (the real job) offers only content the catalog never saw: a copy of known content raises no notice")
    func theRealJobOffersOnlyNewContent() async throws {
        let sb = try ShowAgainSandbox.make("newmedia_job"); defer { sb.cleanup() }
        let known = try sb.record("known.mov", bytes: 4_000, stage: .none)
        let data = try Data(contentsOf: URL(fileURLWithPath: known.fullPath))
        known.contentFixity = ContentFixity(digest: sha(data), byteCount: 4_000,
                                            stamp: FileIdentityStamp.capture(path: known.fullPath) ?? FileIdentityStamp(device: 1, inode: 1, size: 4_000, mtimeNs: 1),
                                            computedAt: savedAt)
        let copy = try sb.record("kno_n.mov", bytes: 4_000, stage: .none)      // same name length + size → the same bytes
        let store = sb.model.newMediaProvenance
        var lines: [String] = []
        store.note = { lines.append($0) }
        store.register([copy.id], why: "scan of test")
        let job = FullHashBackfillJob(model: sb.model, marker: nil)
        job.volumeOnline = { _ in true }
        job.tickMilliseconds = 20
        job.start()
        await job.task?.value
        #expect(copy.contentFixity?.digest == known.contentFixity?.digest, "fixture: the copy is the same content")
        #expect(store.notice == nil, "a copy of content the catalog holds is not new media")
        #expect(store.pending.isEmpty, "settled quietly")

        let fresh = try sb.record("fresh.mov", bytes: 5_000, stage: .none)
        store.register([fresh.id], why: "manual add")
        let second = FullHashBackfillJob(model: sb.model, marker: nil)
        second.volumeOnline = { _ in true }
        second.tickMilliseconds = 20
        second.start()
        await second.task?.value
        #expect(store.notice?.count == 1)
        #expect(store.notice?.contents.first?.recordIDs == [fresh.id])
        #expect(lines.contains("New media: notice shown — 1 new media file came into the catalog — review its provenance when you can."), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("New media: 0 new content(s), 1 cop(ies) of content already in the catalog") }, "\(lines)")
    }

    @Test("remembered per content: an offered digest is never offered again, even from a new path; the queue survives a relaunch")
    func rememberedAndPersisted() throws {
        let folder = try makeTempDir("persist"); defer { try? FileManager.default.removeItem(at: folder) }
        let a = VideoRecord(), waiting = VideoRecord()
        a.fullPath = "/V/test_a.mov"; a.sizeBytes = 64
        a.contentFixity = ContentFixity(digest: hex(1), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: 1, size: 64, mtimeNs: 1), computedAt: savedAt)
        waiting.fullPath = "/V/test_w.mov"; waiting.sizeBytes = 32
        let store = NewMediaProvenanceStore()
        store.attach(folder: folder)
        store.register([a.id, waiting.id], why: "scan of test")
        store.evaluate(records: [a, waiting])
        #expect(store.notice?.count == 1)
        store.skip()

        let relaunched = NewMediaProvenanceStore()
        relaunched.attach(folder: folder)
        #expect(relaunched.pending == [waiting.id], "the file still waiting for its hash is remembered")
        #expect(relaunched.offered == [hex(1)])
        let elsewhere = VideoRecord()
        elsewhere.fullPath = "/W/another/test_a.mov"; elsewhere.sizeBytes = 64
        elsewhere.contentFixity = a.contentFixity
        relaunched.register([elsewhere.id], why: "scan of W")
        relaunched.evaluate(records: [elsewhere, waiting])
        #expect(relaunched.notice == nil, "the same content from another path is not offered again")
    }

    @Test("ISOLATION: an unreadable queue file starts empty and says so; nothing waiting means no work and no notice")
    func poisonedQueueFile() throws {
        let folder = try makeTempDir("poison"); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{not json".utf8).write(to: folder.appendingPathComponent(NewMediaProvenanceStore.fileName))
        let store = NewMediaProvenanceStore()
        var lines: [String] = []
        store.note = { lines.append($0) }
        store.attach(folder: folder)
        #expect(store.pending.isEmpty && store.offered.isEmpty)
        #expect(lines.contains { $0.contains("could not be read") })
        #expect(store.evaluate(records: []).settled.isEmpty)
        #expect(store.notice == nil)
    }

    @Test("the manual add: a file with a full SHA-256 is asked now; one without waits for Full Hashes, and the sheet says so")
    func manualAdd() {
        let bare = VideoRecord()
        bare.sizeBytes = 64
        #expect(WorkspaceImportProvenance.next(for: bare) == .afterFullHashes)
        #expect(WorkspaceImportProvenance.note(for: bare) == NewMediaProvenanceWords.manualAddWaits)
        let hashed = VideoRecord()
        hashed.sizeBytes = 64
        hashed.contentFixity = ContentFixity(digest: hex(2), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: 1, size: 64, mtimeNs: 1), computedAt: savedAt)
        #expect(WorkspaceImportProvenance.next(for: hashed) == .askNow(digest: hex(2)))
    }

    @Test("the review rows: one per content, shown by its first file still in the catalog; the container stamp is labelled as what it is")
    func reviewRows() {
        let a = VideoRecord(), b = VideoRecord()
        a.fullPath = "/Volumes/TestVolume/test_a.mov"; a.filename = "test_a.mov"; a.embeddedCreationDate = savedAt
        b.fullPath = "/V/dir/test_b.mov"; b.filename = "test_b.mov"; b.directory = "/V/dir"
        let gone = UUID()
        let items = ProvenanceReviewItem.make(contents: [.init(digest: hex(1), recordIDs: [gone, a.id]), .init(digest: hex(2), recordIDs: [b.id]),
                                                         .init(digest: hex(3), recordIDs: [gone])],
                                              record: { id in [a, b].first { $0.id == id } }, dateLocked: { $0 === b })
        #expect(items.map(\.filename) == ["test_a.mov", "test_b.mov"], "a content with no file left has no row")
        #expect(items.map(\.place) == [a, b].map { $0.volumeName.isEmpty ? $0.directory : $0.volumeName })
        #expect(items[0].place == "TestVolume")
        #expect(items.map(\.dateLocked) == [false, true])
        #expect(items[1].containerDateText == "Container stamp: unknown")
        #expect(items[0].containerDateText.hasPrefix("Container stamp: "))
    }
}

@Suite("New media — scale")
@MainActor
struct NewMediaProvenanceScaleAppTests {

    @Test("SCALE: 100k records, 10k waiting → the store's evaluation, and the search join of 50k contents, inside their budgets")
    func hundredThousand() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var waiting: [UUID] = []
        var values: [String: ProvenanceFieldValues] = [:]
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/V/\(i).mov"
            r.sizeBytes = 64
            r.contentFixity = ContentFixity(digest: hex(i + 1), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: UInt64(i + 1), size: 64, mtimeNs: 1),
                                            computedAt: savedAt)
            if i >= 90_000 { waiting.append(r.id) }
            if i % 2 == 0 { values[hex(i + 1)] = ProvenanceFieldValues(carrier: "Tape \(i)") }
            records.append(r)
        }
        let store = NewMediaProvenanceStore()
        store.register(waiting, why: "scan of test")
        let clock = ContinuousClock()
        let evaluated = clock.measure { store.evaluate(records: records) }
        #expect(store.notice?.count == 10_000)
        #expect(evaluated < .seconds(2), "\(evaluated)")
        var joined: [String: CatalogSearchIndex.ObservationTerms] = [:]
        let join = clock.measure { joined = ProvenanceFieldsStore.join(records: records, values: values) }
        #expect(joined.count == 50_000)
        #expect(join < .seconds(2), "\(join)")
    }
}

// MARK: - Codex round 2 (2026-11-27): red first, each with Codex's input

/// Seed the provenance estimate's machine rows (inferred master + VHS) for `digest`.
@MainActor
private func seedMachineVHS(_ model: VideoScanModel, _ digest: String) throws {
    let committer = try #require(model.catalogCutover.committer)
    let drafts = [("role", "master"), ("carrier", "VHS")].map { field, value in
        CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: digest, field: field, value: value,
                                            state: "inferred", by: ProvenanceEstimateRule.signer, at: 1,
                                            confidence: 0.9, evidenceJSON: "{}")
    }
    #expect(committer.commitSideTables("seed a machine estimate", via: .provenanceEstimates) { tx in
        for draft in drafts { _ = try tx.appendProvenanceAssertion(draft) }
    } == nil)
}

/// Every reader of the content's carrier: the estimate's projection (the
/// archive badge), the badge itself, the estimate's Inspector line read from
/// catalog.sqlite, the fields' projection and the fields' Inspector reading.
@MainActor
private func carrierEverywhere(_ model: VideoScanModel, _ digest: String) async -> [String: String] {
    var out: [String: String] = [:]
    let estimates = model.provenanceEstimates, roles = model.provenanceRoles
    out["estimate projection"] = estimates.estimate(of: digest)?.carrier ?? "unknown"
    let badge = ProvenanceEstimateMark.judged(estimates.estimate(of: digest), rickRole: roles.role(of: digest), captured: nil,
                                              symbol: ProvenanceEstimateMark.tapeSymbol)
    out["badge"] = badge?.help ?? "none"
    let reading = await estimates.readCurrent(digest: digest)
    out["estimate inspector"] = ProvenanceEstimateMark.inspectorLine(digest: digest, reading: reading, rickRole: roles.role(of: digest),
                                                                     year: nil, captured: nil, technical: nil)?.text ?? "none"
    out["fields projection"] = model.provenanceFields.values(of: digest).carrier ?? "unknown"
    if case .values(_, let v) = await model.provenanceFields.readCurrent(digest: digest) { out["fields inspector"] = v.carrier ?? "unknown" }
    return out
}

@Suite("Provenance fields — Codex round 2 (one carrier reading, search, new media, load)")
@MainActor
struct ProvenanceFieldsRound2AppTests {

    @Test("P0: confirmed VHS → Rick clears the tape ⇒ unknown EVERYWHERE — the estimate's line, its projection and the archive badge too; also after relaunch")
    func clearOfConfirmedVHSReachesEveryReader() async throws {
        let scene = try CutoverScene.make("pf_r2_p0"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        try seedMachineVHS(scene.model, ids.healthy)
        #expect(await scene.model.provenanceEstimates.load() == nil)
        #expect(await scene.model.provenanceRoles.load() == nil)
        #expect(scene.model.provenanceEstimates.confirm(digests: [ids.healthy], now: savedAt) == .confirmed(contents: 1, skipped: 0))
        #expect(scene.model.provenanceFields.values(of: ids.healthy).carrier == "VHS", "the fields hear Confirm's carrier row")
        let fieldsRevision = scene.model.provenanceFields.revision
        let estimatesRevision = scene.model.provenanceEstimates.revision
        #expect(scene.model.provenanceFields.save(digest: ids.healthy, typed: ProvenanceFieldValues(), enteredIn: "inspector",
                                                  now: savedAt.addingTimeInterval(60)) == .saved(changed: 1))
        #expect(scene.model.provenanceEstimates.revision > estimatesRevision, "the estimate's readers re-read (Inspector line, badge)")
        #expect(scene.model.provenanceFields.revision > fieldsRevision)
        let now = await carrierEverywhere(scene.model, ids.healthy)
        #expect(now["estimate projection"] == "unknown", "\(now)")
        #expect(now["badge"] == "none", "\(now)")
        #expect(now["estimate inspector"].map { !$0.contains("VHS") } == true, "\(now)")
        #expect(now["fields projection"] == "unknown" && now["fields inspector"] == "unknown", "\(now)")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(await fresh.provenanceEstimates.load() == nil)
        #expect(await fresh.provenanceRoles.load() == nil)
        let after = await carrierEverywhere(fresh, ids.healthy)
        #expect(after["estimate projection"] == "unknown" && after["badge"] == "none", "\(after)")
        #expect(after["estimate inspector"].map { !$0.contains("VHS") } == true, "\(after)")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P1: inferred VHS → confirm → correct to 'Cape 1994' → clear ⇒ unknown everywhere, never the machine's VHS again; also after relaunch")
    func clearAfterCorrectionNeverResurrects() async throws {
        let scene = try CutoverScene.make("pf_r2_p1"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        try seedMachineVHS(scene.model, ids.healthy)
        #expect(await scene.model.provenanceEstimates.load() == nil)
        #expect(await scene.model.provenanceRoles.load() == nil)
        #expect(scene.model.provenanceEstimates.confirm(digests: [ids.healthy], now: savedAt) == .confirmed(contents: 1, skipped: 0))
        let fields = scene.model.provenanceFields
        #expect(fields.save(digest: ids.healthy, typed: ProvenanceFieldValues(carrier: "Cape 1994"), enteredIn: "inspector",
                            now: savedAt.addingTimeInterval(60)) == .saved(changed: 1))
        let corrected = await carrierEverywhere(scene.model, ids.healthy)
        #expect(corrected["estimate projection"] == "Cape 1994" && corrected["badge"] == "none", "\(corrected)")
        #expect(corrected["estimate inspector"].map { $0.contains("Cape 1994") } == true, "\(corrected)")
        #expect(fields.save(digest: ids.healthy, typed: ProvenanceFieldValues(), enteredIn: "inspector",
                            now: savedAt.addingTimeInterval(120)) == .saved(changed: 1))
        let cleared = await carrierEverywhere(scene.model, ids.healthy)
        #expect(Set(cleared.filter { $0.key.contains("projection") || $0.key == "fields inspector" }.values) == ["unknown"], "\(cleared)")
        #expect(cleared["badge"] == "none", "\(cleared)")
        #expect(cleared["estimate inspector"].map { !$0.contains("VHS") && !$0.contains("Cape") } == true, "\(cleared)")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(await fresh.provenanceEstimates.load() == nil)
        #expect(await fresh.provenanceRoles.load() == nil)
        let after = await carrierEverywhere(fresh, ids.healthy)
        #expect(Set(after.filter { $0.key.contains("projection") || $0.key == "fields inspector" }.values) == ["unknown"], "\(after)")
        #expect(after["badge"] == "none", "\(after)")
        #expect(after["estimate inspector"].map { !$0.contains("VHS") } == true, "\(after)")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P2 search: a retained history row's provenance words never reach a LIVE row at the same path")
    func historyRowWordsStayOut() {
        let history = VideoRecord(), live = VideoRecord()
        for r in [history, live] { r.fullPath = "/V/clip.mov"; r.filename = "clip.mov"; r.sizeBytes = 64 }
        history.contentFixity = ContentFixity(digest: hex(1), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: 1, size: 64, mtimeNs: 1), computedAt: savedAt)
        history.removal = .removedFromCatalog(at: savedAt, reason: .userRemoved)
        live.contentFixity = ContentFixity(digest: hex(2), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: 2, size: 64, mtimeNs: 2), computedAt: savedAt)
        let values = [hex(1): ProvenanceFieldValues(carrier: "Cape 1994")]
        #expect(ProvenanceFieldsStore.join(records: [history, live], values: values)["/V/clip.mov"] == nil)
        #expect(ProvenanceFieldsStore.join(records: [live, history], values: values)["/V/clip.mov"] == nil, "order does not matter")
        let both = [hex(1): ProvenanceFieldValues(carrier: "Cape 1994"), hex(2): ProvenanceFieldValues(carrier: "Tape 2")]
        #expect(ProvenanceFieldsStore.join(records: [live, history], values: both)["/V/clip.mov"]?.words
                == CatalogSearchIndex.ObservationTerms(words: ["tape Tape 2"], years: nil).words)
    }

    @Test("P2 resume: Full Hashes run after a crash between the hash checkpoint and the evaluation still offers the already-hashed new file")
    func resumedJobEvaluatesAlreadyHashedFiles() async throws {
        let sb = try ShowAgainSandbox.make("newmedia_resume"); defer { sb.cleanup() }
        let fresh = try sb.record("fresh_r.mov", bytes: 5_000, stage: .none)
        let data = try Data(contentsOf: URL(fileURLWithPath: fresh.fullPath))
        // The checkpoint landed (the digest is on the record), then the app died before `evaluate`.
        fresh.contentFixity = ContentFixity(digest: sha(data), byteCount: Int64(data.count),
                                            stamp: FileIdentityStamp.capture(path: fresh.fullPath) ?? FileIdentityStamp(device: 1, inode: 1, size: 5_000, mtimeNs: 1),
                                            computedAt: savedAt)
        let store = sb.model.newMediaProvenance
        store.register([fresh.id], why: "scan of test")
        let job = FullHashBackfillJob(model: sb.model, marker: nil)
        job.volumeOnline = { _ in true }
        job.tickMilliseconds = 20
        job.start()
        await job.task?.value
        #expect(store.notice?.contents.first?.recordIDs == [fresh.id], "the waiting file is decided on resume")
        #expect(store.pending.isEmpty)
    }

    @Test("P2 rescan: an open notice's record ids follow a rescan's replacements, so Review still finds the file")
    func noticeFollowsReplacements() {
        let a = VideoRecord()
        a.fullPath = "/V/test_a.mov"; a.filename = "test_a.mov"; a.sizeBytes = 64
        a.contentFixity = ContentFixity(digest: hex(1), byteCount: 64, stamp: FileIdentityStamp(device: 1, inode: 1, size: 64, mtimeNs: 1), computedAt: savedAt)
        let store = NewMediaProvenanceStore()
        store.register([a.id], why: "scan of test")
        store.evaluate(records: [a])
        #expect(store.notice?.contents.first?.recordIDs == [a.id])
        let b = VideoRecord()
        b.fullPath = a.fullPath; b.filename = a.filename; b.sizeBytes = 64; b.contentFixity = a.contentFixity
        store.followReplacements([a.id: b.id])
        #expect(store.notice?.contents.first?.recordIDs == [b.id])
        let items = ProvenanceReviewItem.make(contents: store.notice?.contents ?? [], record: { $0 == b.id ? b : nil }, dateLocked: { _ in false })
        #expect(items.map(\.filename) == ["test_a.mov"], "Review produces the row")
    }

    @Test("P2 same path, new bytes: a known file replaced in place is offered once Full Hashes shows content never seen; an untouched one is not")
    func newBytesAtAKnownPath() async throws {
        let dir = try makeTempDir("samepath"); defer { try? FileManager.default.removeItem(at: dir) }
        try bytes(11).write(to: dir.appendingPathComponent("test_p.mov"))
        try bytes(12).write(to: dir.appendingPathComponent("test_q.mov"))
        let model = pipelineModel()
        let store = model.newMediaProvenance
        var targets = await scan(model, dir, previous: [])
        hashAll(model)
        store.evaluate(records: model.records)
        store.skip()
        try bytes(13).write(to: dir.appendingPathComponent("test_p.mov"))      // same path, new bytes
        targets = await scan(model, dir, previous: targets)
        let p = try #require(model.records.first { $0.filename == "test_p.mov" && $0.removal == nil })
        #expect(store.pending == [p.id], "the replaced file waits for its hash; the untouched one does not")
        hashAll(model)
        store.evaluate(records: model.records)
        #expect(store.notice?.contents.map(\.recordIDs) == [[p.id]])
        _ = targets
    }

    @Test("P2 load: a save during the initial load does not throw the whole snapshot away — the other contents stay searchable")
    func saveDuringInitialLoadKeepsTheSnapshot() async throws {
        let scene = try CutoverScene.make("pf_r2_load"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let committer = try #require(scene.model.catalogCutover.committer)
        // Rows the store has not seen yet (another session's, before this load).
        let draft = CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: ids.other, field: "carrier", value: "Tape A",
                                                        state: "confirmed", by: "rick", at: 1, confidence: nil, evidenceJSON: "{}")
        #expect(committer.commitSideTables("seed", via: .provenanceFields) { tx in _ = try tx.appendProvenanceAssertion(draft) } == nil)
        let store = scene.model.provenanceFields
        #expect(store.values(of: ids.other).isEmpty)
        let loading = Task { await store.load() }
        await Task.yield()
        #expect(store.save(digest: ids.healthy, typed: ProvenanceFieldValues(carrier: "Tape C"), enteredIn: "inspector", now: savedAt) == .saved(changed: 1))
        _ = await loading.value
        #expect(store.values(of: ids.other).carrier == "Tape A", "the snapshot's other contents are kept")
        #expect(store.values(of: ids.healthy).carrier == "Tape C", "the save's read-back wins for its own content")
    }
}

// MARK: - SENSOR

@Suite("Provenance fields — sensors")
@MainActor
struct ProvenanceFieldsSensorAppTests {

    @Test("the views hold no SQL and no commit; the new files add no `extension VideoScanModel`; the store writes through its one door")
    func shape() throws {
        let views = try SourceTree.appCode(named: "Provenance/ProvenanceFieldsViews.swift")
        for token in ["commitSideTables", "writeBlocking", "INSERT", "appendProvenanceAssertion", "import " + "GRDB"] {
            #expect(!views.contains(token), "\(token) in the views")
        }
        for file in ["Provenance/ProvenanceFieldsViews.swift", "Provenance/ProvenanceFieldsStore.swift", "Provenance/NewMediaProvenanceStore.swift"] {
            #expect(!(try SourceTree.appCode(named: file)).contains("extension " + "VideoScanModel"), Comment(rawValue: file))
        }
        let store = try SourceTree.appCode(named: "Provenance/ProvenanceFieldsStore.swift")
        #expect(store.contains("commitSideTables(what, via: .provenanceFields, body)"), "the one door")
        #expect(!store.contains("import " + "GRDB"))
    }

    @Test("the merge registers its strangers and carries waiting files across a rescan; Full Hashes evaluates only after an acknowledged save; the flip attaches the stores")
    func wiring() throws {
        let merge = try SourceTree.appCode(named: "Volumes/VideoScanModel+ScanMerge.swift")
        #expect(merge.components(separatedBy: "newMediaProvenance.register(NewContentFinder.strangers(").count == 3, "complete and partial merges")
        #expect(merge.components(separatedBy: "newMediaProvenance.followReplacements(replacedBy)").count == 3)
        let job = try SourceTree.appCode(named: "MediaOps/FullHashBackfillJob.swift")
        #expect(job.contains("if !saveFailed { model.newMediaProvenance.evaluate(records: model.records) }"),
                "evaluated after every acknowledged save — also a resumed run that stored nothing new (Codex round 2)")
        let flip = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(flip.contains("provenanceFields.attach(ProvenanceFieldsCatalogBacking(committer: committer)"))
        #expect(flip.contains("searchIndex.setObservations(layer, source: .provenance)"))
        #expect(flip.contains("newMediaProvenance.attach(folder:"))
        let content = try SourceTree.appCode(named: "App/ContentView.swift")
        #expect(content.contains("NewMediaProvenanceBanner(store: model.newMediaProvenance"))
    }
}
