// CatalogAuditRowResultsTests.swift
// "Audit Catalog…" tier 0 — the PER-ROW RESULTS in `catalog-audit.json`
// (2026-10-17; SQLite plan v3 §10a D′, codex step-B F6): the marker RECORDS
// what the run decided for every row it asked, so the importer and Fix
// Links can read the audit's answer instead of re-implementing the
// fd-bound walk. Recording only — no marking decision changes.
//   LOGIC     — one row per row asked, with the words the detail list and
//               the console already print; present rows are {id, result}
//               only; the marks on the fixture are exactly what
//               CatalogAuditJobLogicTests.perRowOutcomes pins; the counts
//               EQUAL the per-row tallies; "not asked" rows are counted in
//               bulk and have no row; an older marker without rows still
//               reads; a stopped run keeps its rows but they are not a
//               whole answer (the facts layer's partial rule); the file
//               shape; the O(1) accessor; a duplicate answer is dropped.
//   SCALE     — 100k rows: the publish, the strict read and 100k lookups
//               inside their budgets; the file under 20 MB.
//   ISOLATION — a poisoned rows part (a result word from the future, a
//               duplicate id, tallies that disagree with the counts, not an
//               array, ids not in this catalog) is refused with words; the
//               counts stand; nothing crashes.
//   SENSOR    — the decision sources (CatalogAuditPlan.swift,
//               VideoScanModel+CatalogAudit.swift) do not know the recorder
//               exists; the job records exactly once, after the apply
//               decided and after the tally; the rows ride the one publish.
// Helpers (`runAudit`, the ShowAgainSandbox rows / stamps / lane root) are
// shared from CatalogAuditJobTests.swift.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A scratch folder standing in for a catalog's folder.
private func scratchCatalogFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalog-audit-rows-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func marker(_ json: String, in dir: URL) throws -> CatalogAuditRunRecord? {
    try Data(json.utf8).write(to: dir.appendingPathComponent(CatalogAuditRunMarker.fileName))
    return CatalogFreshnessFactsReader.auditRecord(in: dir)
}

/// A completed run of 2 rows (1 present, 1 gone) with the given rows part.
private func completedRunJSON(rows: String) -> String {
    #"{"startedAt":"2026-10-16T02:00:00Z","finishedAt":"2026-10-16T02:01:00Z","outcome":"completed","partial":false,"#
        + #""counts":{"present":1,"gone":1,"planned":2},"marked":1,"rows":\#(rows)}"#
}

// MARK: - Logic

@Suite("Audit catalog — per-row results: logic", .serialized)
@MainActor
struct CatalogAuditRowResultsTests {

    @Test("every row the run asked is recorded with the words the detail list and console print; present rows are {id, result} only; the marked set is exactly what perRowOutcomes pins")
    func everyAskedRowIsRecordedAndNothingElseChanges() async throws {
        let sb = try ShowAgainSandbox.make("car_rows"); defer { sb.cleanup() }
        let present = try sb.live("present.mov")
        let changed = try sb.live("changed.mov", bytes: 2_000)
        changed.sizeBytes = 1_500
        let gone = try sb.live("gone.mov", onDisk: false, seen: true)
        let back = try sb.missingRow("back.mov", onDisk: true)
        let still = try sb.missingRow("still.mov", onDisk: false, seen: true)
        let archivedGone = try sb.live("arch_gone.mov", onDisk: false, seen: true)
        archivedGone.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 2_000)
        let unseen = try sb.live("unseen.mov", onDisk: false)
        let trash = try sb.live("trash.mov", onDisk: false)
        VideoScanModel.stampRemoval(trash, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
        let marker = CatalogAuditRunMarker()

        let job = await runAudit(sb.model, marker: marker)

        // The marked set — exactly as before the recorder existed.
        #expect(gone.removal?.reason == .missingAtAudit)
        #expect(back.removal == nil)
        #expect(still.removal?.reason == .missingOnDisk)
        #expect(archivedGone.removal == nil)
        #expect(changed.removal == nil)
        #expect(present.removal == nil)
        #expect(unseen.removal == nil)
        #expect(trash.removal?.state == .inTrash)
        #expect(job.storedCount == 2)
        // One answer per row asked; none for the skipped row.
        let last = try #require(marker.lastRun)
        let rows = try #require(last.rows)
        #expect(rows.count == 7)
        #expect(last.rowResult(for: trash.id) == nil)
        #expect(last.rowResult(for: present.id) == CatalogAuditRowResult(id: present.id, result: .present))
        #expect(last.rowResult(for: changed.id)?.result == .changed)
        #expect(last.rowResult(for: gone.id)?.result == .gone)
        #expect(last.rowResult(for: back.id)?.result == .cameBack)
        #expect(last.rowResult(for: still.id)?.result == .stillMissing)
        #expect(last.rowResult(for: archivedGone.id)?.result == .goneArchived)
        #expect(last.rowResult(for: unseen.id)?.result == .neverSeenByAnAudit)
        // The detail words are the ones the detail list (and the console) print.
        for problem in job.problems where problem.result != .notAsked {
            let id = try #require(sb.model.records.first { $0.fullPath == problem.path }?.id)
            #expect(last.rowResult(for: id)?.detail == problem.detail, Comment(rawValue: problem.path))
        }
        #expect(last.rowResult(for: gone.id)?.detail?.contains("marked Missing") == true)
        // Present: no detail, no stamp. Changed and came back: the first pass's stamp. Gone: none.
        #expect(last.rowResult(for: present.id)?.detail == nil)
        #expect(last.rowResult(for: present.id)?.seenOn == nil)
        #expect(last.rowResult(for: changed.id)?.seenOn?.volumeUUID == sb.volumeUUID)
        #expect(last.rowResult(for: back.id)?.seenOn?.volumeUUID == sb.volumeUUID)
        #expect(last.rowResult(for: gone.id)?.seenOn == nil)
        // The counts EQUAL the tallies; the strict reader agrees; a whole answer.
        #expect(CatalogAuditRunRecord.refusal(rows: rows, counts: last.counts) == nil)
        #expect(CatalogAuditRunRecord.tallies(rows) == job.totals.counts)
        #expect(last.rowsRefusal == nil)
        #expect(last.hasCompleteRowResults)
        // The same publish carried both: the file on disk, read strictly, says the same.
        // (Field by field: the stamp's date keeps whole seconds on disk, as catalog.json does.)
        let onDisk = try #require(CatalogFreshnessFactsReader.auditRecord(in: sb.catalogDir))
        #expect(onDisk.rows?.map(\.id) == rows.map(\.id))
        #expect(onDisk.rows?.map(\.result) == rows.map(\.result))
        #expect(onDisk.rows?.map(\.detail) == rows.map(\.detail))
        #expect(onDisk.rows?.map { $0.seenOn?.volumeUUID } == rows.map { $0.seenOn?.volumeUUID })
        #expect(onDisk.counts == last.counts)
        #expect(onDisk.rowResult(for: gone.id) == last.rowResult(for: gone.id))
        // The console words are unchanged.
        let text = sb.catalogLogText()
        #expect(text.contains("gone — marked Missing: \(gone.fullPath)"))
        #expect(text.contains("Audit catalog: OUTCOME — "))
    }

    @Test("rows 'not asked' (a drive not connected) are counted in bulk and have no row; the counts still equal the tallies and the reader accepts the marker")
    func notAskedRowsAreCountedInBulkAndTheReaderAccepts() async throws {
        let sb = try ShowAgainSandbox.make("car_bulk"); defer { sb.cleanup() }
        let offlineRoot = "/Volumes/CARUnmounted_\(UUID().uuidString.prefix(8))"
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/away.mov"; away.filename = "away.mov"; away.sizeBytes = 3_000; away.directory = offlineRoot
        sb.model.records.append(away)
        let here = try sb.live("here.mov")
        let marker = CatalogAuditRunMarker()
        _ = await runAudit(sb.model, marker: marker, online: { !$0.hasPrefix(offlineRoot) })
        let last = try #require(marker.lastRun)
        #expect(last.counts["notAsked"] == 1)
        #expect(last.rows?.count == 1)
        #expect(last.rowResult(for: away.id) == nil)
        #expect(last.rowResult(for: here.id)?.result == .present)
        #expect(last.rowsRefusal == nil)
        #expect(CatalogFreshnessFactsReader.auditRecord(in: sb.catalogDir)?.rows?.count == 1)
    }

    @Test("the marker records the catalog generation after the audit's own save (importer N1, bug 2 of Rick's first dry run): the key on disk equals the catalog file's header generation and the store's")
    func theMarkerRecordsTheCatalogGenerationAfterItsOwnSave() async throws {
        let sb = try ShowAgainSandbox.make("car_gen"); defer { sb.cleanup() }
        _ = try sb.live("present.mov")
        let gone = try sb.live("gone.mov", onDisk: false, seen: true)          // one mark → one acknowledged save
        let marker = CatalogAuditRunMarker()
        _ = await runAudit(sb.model, marker: marker)
        #expect(gone.removal?.reason == .missingAtAudit)
        let onDisk = try #require(CatalogSnapshot.headerProbe(at: URL(fileURLWithPath: sb.model.catalogStore.fileLocation))?.generation)
        #expect(onDisk > 0)
        #expect(onDisk == sb.model.catalogStore.currentGeneration)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sb.auditMarkerFile())) as? [String: Any])
        #expect(json["catalogGeneration"] as? Int == onDisk)
    }

    @Test("every non-present row records the path the audit judged it at (importer N1, bug 3 of Rick's first dry run): the importer's own reader of the file on disk finds it on each, none on a present row, and its preflight refuses nothing")
    func everyNonPresentRowRecordsItsJudgedPath() async throws {
        let sb = try ShowAgainSandbox.make("car_judged"); defer { sb.cleanup() }
        let present = try sb.live("present.mov")
        let changed = try sb.live("changed.mov", bytes: 2_000)
        changed.sizeBytes = 1_500
        let gone = try sb.live("gone.mov", onDisk: false, seen: true)
        let still = try sb.missingRow("still.mov", onDisk: false, seen: true)
        let unseen = try sb.live("unseen.mov", onDisk: false)
        let marker = CatalogAuditRunMarker()
        _ = await runAudit(sb.model, marker: marker)
        let read = try AuditMarkerJSON.decode(Data(contentsOf: sb.auditMarkerFile()))
        let byID = Dictionary(uniqueKeysWithValues: (read.rows ?? []).map { ($0.id, $0) })
        #expect(byID.count == 5)
        #expect(byID[present.id.uuidString]?.judgedPath == nil)
        for rec in [changed, gone, still, unseen] {
            #expect(byID[rec.id.uuidString]?.judgedPath == rec.fullPath, Comment(rawValue: rec.filename))
        }
        #expect(read.faults.isEmpty)
    }

    @Test("an older marker without rows still reads: counts, outcome, launch line and facts as before; rows nil with no refusal")
    func anOlderMarkerWithoutRowsStillReads() throws {
        let dir = try scratchCatalogFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"startedAt":"2026-10-16T02:00:00Z","finishedAt":"2026-10-16T02:01:00Z","outcome":"completed","partial":false,"#
            + #""counts":{"present":9,"gone":1,"planned":10},"marked":1}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(CatalogAuditRunMarker.fileName))
        let marker = CatalogAuditRunMarker()
        let r = try #require(marker.attach(catalogFile: dir.appendingPathComponent("catalog.json").path))
        #expect(r.rows == nil)
        #expect(r.rowsRefusal == nil)
        #expect(r.counts["gone"] == 1)
        #expect(r.rowResult(for: UUID()) == nil)
        #expect(!r.hasCompleteRowResults)
        #expect(CatalogAuditRunMarker.launchLine(r)?.contains("found 1 file(s) gone") == true)
        #expect(CatalogAuditPresenceFacts.from(r).needsDecision == 1)
    }

    @Test("a stopped run keeps the rows it answered, but they are not a whole answer: the facts layer's partial rule stands", .timeLimit(.minutes(1)))
    func aStoppedRunKeepsItsRowsButIsNotAWholeAnswer() async throws {
        let sb = try ShowAgainSandbox.make("car_stop"); defer { sb.cleanup() }
        for i in 0..<12 { try sb.live("stop\(i).mov", onDisk: false, seen: true) }
        let marker = CatalogAuditRunMarker()
        let job = CatalogAuditJob(model: sb.model, marker: marker)
        job.volumeOnline = { _ in true }
        job.laneRoot = sb.laneRoot
        job.tickMilliseconds = 20
        job.chunkSize = 1
        job.statPaths = { paths in Thread.sleep(forTimeInterval: 0.04); return paths.map { _ in .gone } }
        job.start()
        try await Task.sleep(for: .milliseconds(150))
        job.cancel()
        await job.task?.value
        let last = try #require(marker.lastRun)
        #expect(last.outcome == .stopped)
        #expect(job.totals.done > 0)
        #expect(job.totals.done < 12)
        #expect(last.rows?.count == job.totals.done)
        #expect(!last.hasCompleteRowResults)
        #expect(last.rowsRefusal == nil)
        let facts = CatalogAuditPresenceFacts.from(last)
        #expect(facts.outcome == .partial)
        #expect(facts.needsDecision == 0)
        #expect(CatalogFreshnessFactsReader.auditRecord(in: sb.catalogDir)?.rows?.count == job.totals.done)
    }

    @Test("the file shape: a present row is {id, result} only; others carry the detail (and the stamp when written); the accessor is the index; a second answer for a row is dropped; nothing but the file's keys is written")
    func fileShapeAndAccessor() throws {
        var r = CatalogAuditRunRecord(startedAt: Date(timeIntervalSince1970: 1_760_000_000))
        let p = UUID(), g = UUID(), c = UUID()
        let stamp = AuditSeenOn(volumeUUID: "ABC", mountFrom: "/dev/disk9s1", seenAt: Date(timeIntervalSince1970: 1_760_000_000), deviceKey: "k")
        r.noteRow(CatalogAuditRowResult(id: p, apply: CatalogAuditApply(result: .present, detail: "at its path, 2 KB", stamped: true), seenOn: stamp,
                                        judgedPath: "/Volumes/T/p.mov"))
        r.noteRow(CatalogAuditRowResult(id: g, apply: CatalogAuditApply(result: .gone, detail: "not at its path — marked Missing"), seenOn: nil,
                                        judgedPath: "/Volumes/T/g.mov"))
        r.noteRow(CatalogAuditRowResult(id: c, apply: CatalogAuditApply(result: .changed, detail: "on disk 1 KB, the catalog says 2 KB", stamped: true), seenOn: stamp,
                                        judgedPath: "/Volumes/T/c.mov"))
        r.noteRow(CatalogAuditRowResult(id: p, result: .gone))
        r.counts = ["present": 1, "gone": 1, "changed": 1, "planned": 3]
        #expect(r.rows?.count == 3)
        #expect(r.rowResult(for: p) == CatalogAuditRowResult(id: p, result: .present))
        #expect(r.rowResult(for: g)?.detail == "not at its path — marked Missing")
        #expect(r.rowResult(for: g)?.seenOn == nil)
        #expect(r.rowResult(for: c)?.seenOn == stamp)
        #expect(r.rowResult(for: p)?.judgedPath == nil)
        #expect(r.rowResult(for: g)?.judgedPath == "/Volumes/T/g.mov")
        #expect(r.rowResult(for: c)?.judgedPath == "/Volumes/T/c.mov")
        #expect(r.rowResult(for: UUID()) == nil)
        #expect(CatalogAuditRunRecord.refusal(rows: try #require(r.rows), counts: r.counts) == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: try encoder.encode(r), encoding: .utf8))
        #expect(json.contains(#"{"id":"\#(p.uuidString)","result":"present"}"#))
        #expect(json.contains(#""id":"\#(g.uuidString)","judgedPath":"\/Volumes\/T\/g.mov","result":"gone"}"#))
        #expect(!json.contains("rowsRefusal"))
        #expect(!json.contains("\"index\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(CatalogAuditRunRecord.self, from: Data(json.utf8))
        #expect(back == r)
        #expect(back.rowResult(for: c) == r.rowResult(for: c))
    }
}

// MARK: - Scale

@Suite("Audit catalog — per-row results: scale (100k rows)", .serialized)
@MainActor
struct CatalogAuditRowResultsScaleTests {

    /// 100k rows asked (99,890 present, 100 changed with words and a stamp,
    /// 10 gone with words) through the real marker: one publish at the
    /// end, the strict read, 100k lookups. Budgets (Debug, M4 Max): publish
    /// < 2 s, file < 20 MB, read < 2 s, lookups < 1 s.
    @Test(.timeLimit(.minutes(2)))
    func publishAndReadAt100k() throws {
        let dir = try scratchCatalogFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let marker = CatalogAuditRunMarker()
        marker.attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        marker.noteStarted()
        var totals = CatalogAuditTotals()
        totals.planned = 100_000
        var ids: [UUID] = []
        ids.reserveCapacity(100_000)
        let stamp = AuditSeenOn(volumeUUID: "ABC", mountFrom: "/dev/disk9s1", seenAt: Date(), deviceKey: "k")
        for i in 0..<100_000 {
            let id = UUID()
            ids.append(id)
            if i % 10_000 == 0 {
                marker.noteRow(CatalogAuditRowResult(id: id, apply: CatalogAuditApply(
                    result: .gone, detail: "not at its path, in a folder on the drive it was last seen on, at the moment of marking — marked Missing"), seenOn: nil,
                    judgedPath: "/Volumes/Archive1/Family/1987/tape_\(i).mov"))
                totals.add(.gone)
            } else if i % 1_000 == 1 {
                marker.noteRow(CatalogAuditRowResult(id: id, apply: CatalogAuditApply(
                    result: .changed, detail: "on disk 1.5 MB, the catalog says 2.0 MB — replaced since it was cataloged? Not marked; Update Catalog rescans it",
                    stamped: true), seenOn: stamp, judgedPath: "/Volumes/Archive1/Family/1987/tape_\(i).mov"))
                totals.add(.changed)
            } else {
                marker.noteRow(CatalogAuditRowResult(id: id, apply: CatalogAuditApply(result: .present, detail: "at its path, 2 MB", stamped: true), seenOn: stamp,
                                                     judgedPath: "/Volumes/Archive1/Family/1987/tape_\(i).mov"))
                totals.add(.present)
            }
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let wrote = clock.measure { marker.noteFinished(.completed, totals: totals, marked: 10, partial: false, catalogGeneration: nil) }
        let file = dir.appendingPathComponent(CatalogAuditRunMarker.fileName)
        let bytes = try #require((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? Int)
        #expect(bytes < 20_000_000, "\(bytes) bytes")
        expectWithinTimingBudget("audit marker publish with 100k rows", measured: wrote,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
        var read: CatalogAuditRunRecord?
        let reading = clock.measure { read = CatalogFreshnessFactsReader.auditRecord(in: dir) }
        let r = try #require(read)
        #expect(r.rows?.count == 100_000)
        #expect(r.rowsRefusal == nil)
        #expect(r.hasCompleteRowResults)
        expectWithinTimingBudget("audit marker strict read with 100k rows", measured: reading,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
        var found = 0
        let lookups = clock.measure { for id in ids where r.rowResult(for: id) != nil { found += 1 } }
        #expect(found == 100_000)
        expectWithinTimingBudget("100k rowResult lookups", measured: lookups,
                                 budget: PerformanceLane.debugCeiling(.seconds(1)), loadBefore: load)
        #expect(r.rowResult(for: ids[0])?.result == .gone)
        print("audit marker at 100k rows: \(bytes) bytes · publish \(wrote) · strict read \(reading) · 100k lookups \(lookups)")
    }
}

// MARK: - Isolation

@Suite("Audit catalog — per-row results: isolation (poisoned rows part)", .serialized)
@MainActor
struct CatalogAuditRowResultsIsolationTests {

    struct Poison: Sendable, CustomTestStringConvertible {
        let label: String
        let rows: String
        let expectedWords: String
        var testDescription: String { label }
    }

    nonisolated static let twice = UUID()
    nonisolated static let poisons: [Poison] = [  // Swift 6: the @Test macro reads it off the actor
        Poison(label: "a result word from the future",
               rows: #"[{"id":"\#(UUID().uuidString)","result":"present"},{"id":"\#(UUID().uuidString)","result":"vaporised","detail":"x"}]"#,
               expectedWords: "a result word this version does not know (\"vaporised\")"),
        Poison(label: "the same row answered twice",
               rows: #"[{"id":"\#(twice.uuidString)","result":"present"},{"id":"\#(twice.uuidString)","result":"gone","detail":"x"}]"#,
               expectedWords: "answer row \(twice.uuidString) twice"),
        Poison(label: "tallies that disagree with the counts",
               rows: #"[{"id":"\#(UUID().uuidString)","result":"present"},{"id":"\#(UUID().uuidString)","result":"present"}]"#,
               expectedWords: "disagree with the counts (present: counts say 1, rows say 2)"),
        Poison(label: "not an array", rows: "5", expectedWords: "could not be read"),
        Poison(label: "an object instead of an array", rows: #"{"id":"x"}"#, expectedWords: "could not be read"),
        Poison(label: "a row without an id", rows: #"[{"result":"present"}]"#, expectedWords: "could not be read"),
    ]

    @Test("a poisoned rows part is refused with words; the counts, the outcome and the facts stand; nothing crashes", arguments: poisons)
    func poisonedRowsAreRefusedAndTheCountsKept(_ poison: Poison) throws {
        let dir = try scratchCatalogFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try #require(try marker(completedRunJSON(rows: poison.rows), in: dir))
        #expect(r.rows == nil)
        #expect(r.rowsRefusal?.words.contains(poison.expectedWords) == true, Comment(rawValue: r.rowsRefusal?.words ?? "no refusal"))
        #expect(r.rowsRefusal?.words.contains("the counts stand") == true)
        #expect(r.counts["gone"] == 1)
        #expect(r.outcome == .completed)
        #expect(!r.hasCompleteRowResults)
        #expect(r.rowResult(for: Self.twice) == nil)
        #expect(CatalogAuditPresenceFacts.from(r).needsDecision == 1)
        // The run marker reads it the same way.
        let viaMarker = CatalogAuditRunMarker().attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        #expect(viaMarker?.rowsRefusal == r.rowsRefusal)
    }

    @Test("a sound rows part reads; the outcome word stays strict (a newer schema is still nil, as before)")
    func aSoundRowsPartReadsAndTheOutcomeStaysStrict() throws {
        let dir = try scratchCatalogFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID()
        let sound = #"[{"id":"\#(a.uuidString)","result":"present"},{"id":"\#(b.uuidString)","result":"gone","detail":"marked Missing"}]"#
        let r = try #require(try marker(completedRunJSON(rows: sound), in: dir))
        #expect(r.rows?.count == 2)
        #expect(r.rowsRefusal == nil)
        #expect(r.rowResult(for: b)?.detail == "marked Missing")
        #expect(r.hasCompleteRowResults)
        let newer = completedRunJSON(rows: sound).replacingOccurrences(of: "\"completed\"", with: "\"somethingNewer\"")
        #expect(try marker(newer, in: dir) == nil)
    }

    @Test("rows naming ids this catalog does not have are refused against the catalog; the counts stand; a marker of this catalog passes unchanged")
    func foreignIDsAreRefusedAgainstTheCatalog() {
        var r = CatalogAuditRunRecord(startedAt: Date())
        let a = UUID(), b = UUID()
        r.noteRow(CatalogAuditRowResult(id: a, result: .present))
        r.noteRow(CatalogAuditRowResult(id: b, result: .gone, detail: "x"))
        r.counts = ["present": 1, "gone": 1, "planned": 2]
        #expect(r.checkedAgainstCatalog(ids: [a, b, UUID()]) == r)
        let refused = r.checkedAgainstCatalog(ids: [a])
        #expect(refused.rows == nil)
        #expect(refused.rowsRefusal == .idsNotInCatalog(1))
        #expect(refused.rowResult(for: a) == nil)
        #expect(refused.counts == r.counts)
        #expect(refused.rowsRefusal?.words.contains("1 per-row result(s) name rows this catalog does not have") == true)
    }
}

// MARK: - Sensor

@Suite("Audit catalog — per-row results: sensor (recording only, after the decision)")
@MainActor
struct CatalogAuditRowResultsSensorTests {

    @Test("the decision sources do not know the recorder; the job records exactly once, after the apply decided and after the tally; the rows ride the one publish")
    func theRecorderIsInvisibleToTheDecisionSources() throws {
        let recorder = ["noteRow", "CatalogAuditRowResult", "rowResult(", "CatalogAuditRunMarker", "rowsRefusal", "hasCompleteRowResults"]
        for name in ["CatalogAuditPlan.swift", "VideoScanModel+CatalogAudit.swift"] {
            let code = try CatalogAuditJobSensorTests.code(name)
            for token in recorder { #expect(!code.contains(token), "\(name) knows the recorder (\(token))") }
        }
        let job = try CatalogAuditJobSensorTests.code("CatalogAuditJob.swift")
        #expect(job.components(separatedBy: "marker?.noteRow(").count == 2, "exactly one record call")
        let apply = try #require(job.range(of: "model.applyCatalogAudit(observation.stat, seenOn: observation.seenOn, to: item)"))
        let tally = try #require(job.range(of: "totals.add(apply.result)"))
        let note = try #require(job.range(of: "marker?.noteRow(CatalogAuditRowResult(id: item.id, apply: apply, seenOn: observation.seenOn, judgedPath: item.path))"),
                               "the judged path is the planned path the stat and the apply looked at (importer N1)")
        #expect(apply.upperBound < note.lowerBound, "the row is recorded after the apply decided")
        #expect(tally.upperBound < note.lowerBound, "…and after the tally the counts come from")
        let run = try CatalogAuditJobSensorTests.code("CatalogAuditRun.swift")
        #expect(run.components(separatedBy: "AtomicFilePublish.write(data, to: fileURL").count == 2, "one publish carries the counts and the rows")
        #expect(run.contains("try c.encodeIfPresent(rows, forKey: .rows)"), "the rows are part of the record, not a second file")
        #expect(run.contains("guard let result = CatalogAuditResult(rawValue: word) else { throw UnknownResultWord(word: word) }"),
                "the result vocabulary is the counts' vocabulary; an unknown word is a refusal, never a crash")
    }
}
