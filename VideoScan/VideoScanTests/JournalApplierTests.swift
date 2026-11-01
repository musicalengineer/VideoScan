// JournalApplierTests.swift — the background helper's journal into
// catalog.sqlite through the one commit door (JournalApplier.swift; Core's
// JournalApplication is the batch body, its own suite covers each refusal
// rule and the 100k / 256-line scale budget).
//
// Dimensions (CLAUDE.md rule 8, a catalog writer):
//   TRUTH      lines in the journal before launch are in catalog.sqlite after
//              the launch pass, read back from the store; the cursor sits at
//              the end; the OUTCOME line carries files · read · applied ·
//              duplicates · refused · rows before/after; Catalog Status says
//              "Background: N journal lines waiting · M refused".
//   LOGIC      applying a file twice (cursor lost) = once: all duplicates, no
//              new row; refused lines (unknown digest, vetoed) land in
//              refused.jsonl with their rule and in the count.
//   ISOLATION  a garbage line is refused "invalid" and passed; a torn tail
//              (no newline) is not applied and not counted; once the helper
//              seals it, it is refused "invalid".
//   WRITER     inside the 2 s debounce window of a record edit (both land,
//              both survive the relaunch); during a job's write hold (nothing
//              read past the cursor, the lines wait and are counted, then
//              land after release); across a viewer/master flip (waits as
//              viewer, lands as master); relaunch with lines still waiting
//              (the next launch applies them).
//   SENSOR     the applier holds no SQL; it writes only through
//              commitSideTables(via: .observations); no `extension
//              VideoScanModel` in it.
//   SCALE      Core: JournalApplicationTests (100k lines, worst batch ≤ 0.1 s).
//   MEDIA      N/A — no media is opened.
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let machineBy = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

@MainActor
private func journalFolder(_ scene: CutoverScene) -> URL {
    scene.folder.appendingPathComponent("background/journal", isDirectory: true)
}

@MainActor
private func journal(_ scene: CutoverScene) -> ObservationJournal {
    ObservationJournal(directory: journalFolder(scene))
}

private func observation(_ digest: String, value: String = "1991-1995", at: Int64 = 1_762_000_000, unit: Int = 0) throws -> ObservationLine {
    try ObservationLine(subjectID: digest, field: "era.yearRange", value: value, by: machineBy, at: at, confidence: 0.6,
                        evidence: ["window": [10.0, 70.0], "rationale": "synthetic"], job: "TEST-JOB", unit: unit)
}

@MainActor
private func digest(_ scene: CutoverScene, _ shape: PoisonedCatalogFixture.Shape) throws -> String {
    try #require(CatalogCommit.digest(of: try scene.record(shape)))
}

/// The digests of the fixture's main rows, without launching (import first).
@MainActor
private func launch(_ scene: CutoverScene) async throws -> JournalApplier.PassOutcome {
    try await scene.launchOnSQLite()
    try #require(scene.model.catalogCutover.isSQLiteAuthority, "the scene launched on catalog.sqlite")
    return try #require(await scene.model.journalApplier.launchPass?.value)
}

@MainActor
private func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> (VideoScanModel, JournalApplier.PassOutcome) {
    model.journalApplier.detach()
    if let committer = model.catalogCutover.committer { await committer.repository.close() }
    let sandbox = scene.sandbox
    let fresh = VideoScanModel(logDirectory: sandbox.logs)
    fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
    fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
    fresh.records = fresh.loadCatalogAtLaunch()
    try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
    let pass = try #require(await fresh.journalApplier.launchPass?.value)
    return (fresh, pass)
}

@MainActor
private func stored(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.ProvenanceAssertionReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: digest) }
}

@MainActor
private func rowCount(_ model: VideoScanModel) async throws -> Int {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertionCount() }
}

@MainActor
private func close(_ model: VideoScanModel) async {
    model.journalApplier.detach()
    if let c = model.catalogCutover.committer { await c.repository.close() }
}

@Suite("JournalApplier — the helper's journal into catalog.sqlite", .serialized)
@MainActor
struct JournalApplierTruthTests {

    @Test("TRUTH: lines written before launch are in catalog.sqlite after the launch pass; cursor at the end; OUTCOME and the Catalog Status line say so")
    func launchPassAppliesAndSays() async throws {
        let scene = try CutoverScene.make("journal_truth"); defer { scene.cleanup() }
        try await scene.importCatalog()
        // The fixture's digests are known before launch from the import.
        let preview = try await scene.sqliteLoad()
        let healthy = try #require(preview.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) }.flatMap(CatalogCommit.digest(of:)))
        try journal(scene).append([try observation(healthy), try observation(healthy, value: "1990-1994", unit: 1)])
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let pass = try #require(await scene.model.journalApplier.launchPass?.value)
        #expect(pass.applied == 2)
        #expect(pass.rowsBefore == 0)
        #expect(pass.rowsAfter == 2)
        let rows = try await stored(scene.model, healthy)
        #expect(rows.map(\.value).sorted() == ["1990-1994", "1991-1995"])
        #expect(rows.allSatisfy { $0.by == machineBy && $0.state == "inferred" && $0.confidence == 0.6 })
        let j = journal(scene)
        let file = try #require(j.dayFiles().first)
        #expect(j.appliedOffset(file) == j.size(of: file))
        #expect(scene.model.journalApplier.counts == JournalApplier.Counts(waiting: 0, refused: 0))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Background journal: OUTCOME applied — 1 file · 2 lines read · 2 applied · 0 duplicates · 0 refused; rows before 0 · after 2"), "\(log.suffix(800))")
        #expect(log.contains("via background observations"), "the committer's own line names the door")
        #expect(JournalApplierWords.statusLine(JournalApplier.Counts(waiting: 3, refused: 1)) == "Background: 3 journal lines waiting · 1 refused")
        #expect(CatalogRealityFactsBuilder.information(IntegrityReportFacts(), backgroundJournal: JournalApplier.Counts(waiting: 1, refused: 0))
                    .contains("Background: 1 journal line waiting · 0 refused"))
        #expect(!CatalogRealityFactsBuilder.information(IntegrityReportFacts()).contains { $0.hasPrefix("Background:") },
                "no line before the applier has counted")
        await close(scene.model)
    }

    @Test("LOGIC: a file applied twice (its cursor lost) is applied once — every line a duplicate, no new row")
    func applyTwiceIsOnce() async throws {
        let scene = try CutoverScene.make("journal_twice"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        let j = journal(scene)
        try j.append([try observation(d), try observation(d, value: "1980-1984", unit: 1)])
        let first = await scene.model.journalApplier.applyPending()
        #expect(first.applied == 2)
        let file = try #require(j.dayFiles().first)
        try FileManager.default.removeItem(at: journalFolder(scene).appendingPathComponent(file + ObservationJournal.appliedSuffix))
        let second = await scene.model.journalApplier.applyPending()
        #expect(second.applied == 0)
        #expect(second.duplicates == 2)
        #expect(try await rowCount(scene.model) == 2)
        await close(scene.model)
    }

    @Test("LOGIC: refused lines (unknown digest, vetoed by Rick's rejection) land in refused.jsonl with their rule and in the count")
    func refusedLinesLandWithTheirRule() async throws {
        let scene = try CutoverScene.make("journal_refused"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.commitSideTables("Rick rejects 1950-1955", via: .observations) { tx in
            _ = try tx.appendProvenanceAssertion(CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: d, field: "era.yearRange",
                                                                                   value: "1950-1955", state: "rejected", by: "rick", at: 1,
                                                                                   confidence: nil, evidenceJSON: "{}"))
        } == nil)
        try journal(scene).append([try observation(String(format: "%064x", 0xdead)), try observation(d, value: "1950-1955"), try observation(d)])
        let pass = await scene.model.journalApplier.applyPending()
        #expect(pass.applied == 1)
        #expect(pass.refused == 2)
        let reasons = journal(scene).refusedRecords().compactMap { $0["reason"] as? String }.sorted()
        #expect(reasons == ["unknownDigest", "vetoed"])
        #expect(scene.model.journalApplier.counts == JournalApplier.Counts(waiting: 0, refused: 2))
        await close(scene.model)
    }

    @Test("ISOLATION: a garbage line is refused 'invalid' and passed; a torn tail is neither applied nor counted until the helper seals it")
    func garbageAndTornTail() async throws {
        let scene = try CutoverScene.make("journal_torn"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        let j = journal(scene)
        try j.append([try observation(d)])
        let file = try #require(j.dayFiles().first)
        let handle = try FileHandle(forWritingTo: journalFolder(scene).appendingPathComponent(file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,garbage}\n".utf8) + (try observation(d, value: "1970-1975")).encoded.prefix(30))
        try handle.close()
        let pass = await scene.model.journalApplier.applyPending()
        #expect(pass.applied == 1)
        #expect(pass.refused == 1)
        #expect(j.refusedRecords().first?["reason"] as? String == "invalid")
        #expect(scene.model.journalApplier.counts?.waiting == 0, "a torn tail is not a waiting line")
        try j.append([try observation(d, value: "1970-1975")])      // the helper's next run seals and re-appends
        let next = await scene.model.journalApplier.applyPending()
        #expect(next.applied == 1)
        #expect(next.refused == 1, "the sealed fragment")
        #expect(try await rowCount(scene.model) == 2)
        await close(scene.model)
    }
}

@Suite("JournalApplier — the writer quartet on catalog.sqlite", .serialized)
@MainActor
struct JournalApplierWriterTests {

    @Test("WRITER: a pass inside the 2 s debounce window of a record edit — both land, both survive the relaunch")
    func insideTheDebounceWindow() async throws {
        let scene = try CutoverScene.make("journal_debounce"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let healthy = try scene.record(.healthy)
        let d = try digest(scene, .healthy)
        healthy.userNotes = "typed just before the journal pass"
        scene.model.saveCatalogDebounced()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the edit is waiting on the debounce timer")
        try journal(scene).append([try observation(d)])
        #expect(await scene.model.journalApplier.applyPending().applied == 1)
        #expect(committer.blockedReason == nil, "the side-table commit did not block the record commit")
        #expect(scene.model.saveCatalogNow(), "the edit inside the window still commits")
        let (fresh, pass) = try await relaunch(scene, from: scene.model)
        #expect(pass.linesRead == 0, "the cursor survived: nothing re-read")
        #expect(try await stored(fresh, d).count == 1)
        #expect(fresh.records.first { $0.id == healthy.id }?.userNotes == "typed just before the journal pass")
        await close(fresh)
    }

    @Test("WRITER: during a job's write hold nothing is read past the cursor — the lines wait and are counted, then land after release and survive the relaunch")
    func duringAWriteHold() async throws {
        let scene = try CutoverScene.make("journal_hold"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        let j = journal(scene)
        try j.append([try observation(d), try observation(d, value: "1985-1989", unit: 1)])
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let held = await scene.model.journalApplier.applyPending()
        #expect(held.waitingBecause?.contains("held — a test job") == true, "\(held.waitingBecause ?? "nil")")
        #expect(held.applied == 0)
        #expect(try await rowCount(scene.model) == 0, "nothing written")
        #expect(j.appliedOffset(try #require(j.dayFiles().first)) == 0, "the cursor did not move")
        #expect(scene.model.journalApplier.counts?.waiting == 2)
        #expect(scene.sandbox.catalogLogText().contains("Background journal: waiting — the catalog cannot take journal lines now"))
        scene.model.catalogStore.releaseWriteHold()
        #expect(await scene.model.journalApplier.applyPending().applied == 2)
        #expect(scene.model.journalApplier.counts?.waiting == 0)
        let (fresh, _) = try await relaunch(scene, from: scene.model)
        #expect(try await stored(fresh, d).count == 2)
        await close(fresh)
    }

    @Test("WRITER: across a viewer/master flip — waits as viewer (nothing written), lands as master; the relaunch shows the rows")
    func acrossAViewerMasterFlip() async throws {
        let scene = try CutoverScene.make("journal_flip"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        try journal(scene).append([try observation(d)])
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let viewer = await scene.model.journalApplier.applyPending()
        #expect(viewer.waitingBecause?.contains("viewer") == true, "\(viewer.waitingBecause ?? "nil")")
        #expect(try await rowCount(scene.model) == 0)
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(await scene.model.journalApplier.applyPending().applied == 1)
        let (fresh, _) = try await relaunch(scene, from: scene.model)
        #expect(try await stored(fresh, d).count == 1)
        await close(fresh)
    }

    @Test("WRITER: quit with lines still waiting (held) — the next launch's pass applies them")
    func relaunchAppliesWhatWaited() async throws {
        let scene = try CutoverScene.make("journal_relaunch"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let d = try digest(scene, .healthy)
        try journal(scene).append([try observation(d)])
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(await scene.model.journalApplier.applyPending().applied == 0)
        scene.model.catalogStore.releaseWriteHold()
        let (fresh, pass) = try await relaunch(scene, from: scene.model)
        #expect(pass.applied == 1)
        #expect(try await stored(fresh, d).count == 1)
        await close(fresh)
    }
}

@Suite("JournalApplier — sensors")
struct JournalApplierSensorTests {

    private static var source: String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent("VideoScan/Catalog/JournalApplier.swift"), encoding: .utf8)) ?? ""
    }

    @Test("the applier holds no SQL, writes only through the observations side-table door, and does not extend the model")
    func onlyTheDoor() {
        let code = Self.source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(!code.isEmpty)
        for word in ["INSERT ", "SELECT ", "UPDATE ", "DELETE ", "writeBlocking", "execute("] {
            #expect(!code.contains(word), "\(word)")
        }
        #expect(code.contains("commitSideTables(what, via: .observations, body)"))
        #expect(!code.contains("extension VideoScanModel"))
    }
}
