// ArchiveAngelSkipEntryTests.swift
// "Skip this file for this batch" (Rick 2026-09-13, watching a batch roll
// by): a per-entry skip that is NOT a cancel and NOT a failure. The state
// machine lives on the plan (`ArchiveAngelPlan.skipEntry`, `Entry.loopAction`)
// so it can be tested without ffmpeg, a catalog or a job; the job only owns
// the side effects (cancel that row's sub-job, reclaim its buffer folder,
// save the plan).
//
// Five dimensions (project checklist): logic · persistence · isolation ·
// sensor · scale. Temp dirs only; nothing outside the test's own folder.

import Foundation
import SwiftUI
import Testing
@testable import VideoScan

@Suite("Archive Angel — skipping one entry for this batch (Rick 2026-09-13)")
struct ArchiveAngelSkipEntryTests {

    // MARK: Fixtures

    private func entry(_ status: ArchiveAngelPlan.EntryStatus,
                       _ filename: String = "tape.mov",
                       id: UUID = UUID()) -> ArchiveAngelPlan.Entry {
        .init(id: id, sourcePath: "/vol/\(filename)", filename: filename, sizeBytes: 1_000,
              durationSeconds: 3_600, score: 40, evidence: [], proposedName: filename,
              proposedDate: "1993", status: status)
    }

    private func plan(_ dir: String, _ rows: [ArchiveAngelPlan.Entry],
                      status: ArchiveAngelPlan.Status = .preparing) -> ArchiveAngelPlan {
        var p = ArchiveAngelPlan(batchDir: dir, requestedCount: rows.count, makeLossless: false, entries: rows)
        p.status = status
        return p
    }

    /// The note the job passes to `skipEntry` — the same closure shape.
    private let note = ArchiveAngelJob.skipNote

    // MARK: - 1. Logic — the state transitions

    @Test("a row waiting for buffer space is skippable right away (Rick 2026-09-19); a genuinely failed row is not")
    func bufferShortRowIsSkippable() {
        var waiting = entry(.failed, "big.mxf")
        waiting.failure = ArchiveAngelPlan.bufferShortNote(need: 50_000_000_000, free: 10_000_000_000)
        var broken = entry(.failed, "bad.mov")
        broken.failure = "Transcode failed: exit code 69"
        #expect(waiting.isBufferShort && waiting.isSkippable)
        #expect(!broken.isBufferShort && !broken.isSkippable)
        var p = plan("/tmp/x", [waiting, broken])
        #expect(p.skipEntry(id: waiting.id, note: note)?.previous == .failed)
        #expect(p.entries[0].status == .skipped && p.entries[0].failure == nil, "the waiting note is cleared by the skip")
        #expect(p.skipEntry(id: broken.id, note: note) == nil)
        #expect(p.entries[1].status == .failed)
    }

    @Test("skip is accepted from pending, preparing and ready; refused once the row is settled")
    func skippableStates() {
        for from in [ArchiveAngelPlan.EntryStatus.pending, .preparing, .ready] {
            var p = plan("/tmp/x", [entry(from)])
            let out = p.skipEntry(id: p.entries[0].id, note: note)
            #expect(out?.previous == from, "\(from.rawValue) must be skippable")
            #expect(p.entries[0].status == .skipped)
            #expect(p.entries[0].skippedAt != nil, "the row remembers WHEN it was skipped")
            #expect(p.entries[0].skipNote?.isEmpty == false, "…and says so in words")
        }
        for from in [ArchiveAngelPlan.EntryStatus.promoted, .failed, .skipped] {
            var p = plan("/tmp/x", [entry(from)])
            let refused = p.skipEntry(id: p.entries[0].id, note: note)
            #expect(refused == nil, "\(from.rawValue) is already settled")
            #expect(p.entries[0].status == from, "…and is left exactly as it was")
        }
        var unknown = plan("/tmp/x", [entry(.pending)])
        let missing = unknown.skipEntry(id: UUID(), note: note)
        #expect(missing == nil, "an id that is not in the batch is a no-op")
        #expect(unknown.entries[0].status == .pending)
    }

    @Test("a skip is a decision, not a breakage: `failure` is cleared and the status is NOT .failed")
    func skipIsNotAFailure() {
        var p = plan("/tmp/x", [entry(.preparing)])
        p.entries[0].failure = "Access copy did not finish"
        _ = p.skipEntry(id: p.entries[0].id, note: note)
        #expect(p.entries[0].status == .skipped)
        #expect(p.entries[0].status != .failed, "skipped and failed are different statuses, on purpose")
        #expect(p.entries[0].failure == nil, "a stale failure line must not survive the user's decision")
        #expect(p.entries[0].skipNote?.lowercased().contains("fail") == false, "the note never says 'failed'")
    }

    @Test("the note distinguishes 'you stopped it mid-preparation' from 'you dropped a prepared row'")
    func skipNoteWording() {
        let when = Date()
        #expect(ArchiveAngelJob.skipNote(was: .preparing, at: when).contains("while it was preparing"))
        #expect(ArchiveAngelJob.skipNote(was: .pending, at: when).contains("while it was pending"))
        #expect(ArchiveAngelJob.skipNote(was: .ready, at: when).contains("after it was prepared"))
        #expect(ArchiveAngelJob.skipNote(was: .pending, at: when).contains("not in this batch"),
                "scope is the batch — never a durable 'do not propose this again'")
    }

    // MARK: - 2. Logic — what the preparation loop does with each row

    @Test("loop action: skipped rows are reclaimed-and-passed, never prepared")
    func loopActionPerStatus() {
        #expect(entry(.pending).loopAction == .prepare)
        #expect(entry(.preparing).loopAction == .prepare)
        #expect(entry(.skipped).loopAction == .reclaimBuffer)
        #expect(entry(.ready).loopAction == .passOver)
        #expect(entry(.promoted).loopAction == .passOver)
        #expect(entry(.failed).loopAction == .passOver)
    }

    @Test("skipping the live entry leaves the rest of the batch to prepare — the loop advances, it does not stop")
    func skipMidBatchAdvances() {
        var p = plan("/tmp/x", [entry(.ready, "a.mov"), entry(.preparing, "b.mov"),
                                entry(.pending, "c.mov"), entry(.pending, "d.mov")])
        _ = p.skipEntry(id: p.entries[1].id, note: note)   // the golden in-progress one

        let actions = p.entries.map(\.loopAction)
        #expect(actions == [.passOver, .reclaimBuffer, .prepare, .prepare],
                "the two rows after the skipped one are still prepared — a skip is not a cancel")
        #expect(p.entries.contains { $0.loopAction == .prepare }, "the batch still has work; it does not end here")
        #expect(p.skippedCount == 1)
        #expect(p.readyCount == 1, "an already-prepared row is untouched by a skip elsewhere")
    }

    @Test("skipping the last pending entry finishes the batch normally — nothing left to prepare, ready rows survive")
    func skipLastPendingFinishes() {
        var p = plan("/tmp/x", [entry(.ready, "a.mov"), entry(.ready, "b.mov"), entry(.pending, "c.mov")])
        _ = p.skipEntry(id: p.entries[2].id, note: note)
        #expect(!p.entries.contains { $0.loopAction == .prepare }, "the loop runs out of work and falls through to the finish")
        #expect(p.readyCount == 2, "the batch is still reviewable")
        #expect(p.skippedCount == 1)
        // The finish line the job prints: "2 ready to review · 1 skipped · …"
        #expect(p.skippedClause == " · 1 skipped")
        #expect(plan("/tmp/y", [entry(.ready)]).skippedClause.isEmpty, "no skips ⇒ no clause")
    }

    @Test("summary: skips are counted apart from failures and never folded into them")
    func reportSummarySeparatesSkipsFromFailures() {
        var report = ArchiveAngelPlan.Report()
        report.promotedOriginals = 2
        report.accessCopies = 2
        report.failed = ["broke.mov"]
        report.skippedByUser = ["nope.mov", "notthis.mov", "later.mov"]
        let s = report.summary
        #expect(s.contains("3 skipped: nope.mov, notthis.mov, later.mov"))
        #expect(s.contains("1 failed: broke.mov"))
        #expect(!s.contains("4 failed"), "a skip is never reported as a failure")
    }

    // MARK: - 3. Persistence — plan.json round-trip and a settle

    @Test("plan.json round-trips the skipped status, the note and the timestamp")
    func roundTrip() throws {
        let dir = Self.tempDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = plan(dir.path, [entry(.ready, "a.mov"), entry(.preparing, "b.mov")])
        let when = Date()
        _ = p.skipEntry(id: p.entries[1].id, now: when, note: note)
        try ArchiveAngelPlanStore.save(p)

        let loaded = try ArchiveAngelPlanStore.load(batchDir: dir.path)
        #expect(loaded.entries[1].status == .skipped)
        #expect(loaded.entries[1].skipNote == p.entries[1].skipNote)
        #expect(abs((loaded.entries[1].skippedAt ?? .distantPast).timeIntervalSince(when)) < 1.5,
                "iso8601 second resolution is enough to say when")
        #expect(loaded.skippedCount == 1)
        #expect(loaded.entries[0].skippedAt == nil, "an untouched row carries no skip metadata")
    }

    @Test("a skip survives an interruption: settle never turns it into failed or ready")
    func skipSurvivesSettle() {
        var p = plan("/tmp/x", [entry(.ready, "a.mov"), entry(.preparing, "b.mov"),
                                entry(.pending, "c.mov"), entry(.promoted, "d.mov")])
        _ = p.skipEntry(id: p.entries[1].id, note: note)
        let noteBefore = p.entries[1].skipNote
        let stampBefore = p.entries[1].skippedAt

        let kept = p.settleAfterInterruption(reason: "Cancelled before it was prepared")

        #expect(kept)
        #expect(p.entries.map(\.status) == [.ready, .skipped, .failed, .promoted],
                "only pending/preparing rows are settled into failures")
        #expect(p.entries[1].failure == nil, "a skipped row picks up no failure reason")
        #expect(p.entries[1].skipNote == noteBefore && p.entries[1].skippedAt == stampBefore)
        #expect(p.log.last?.contains("1 skipped by you") == true, "the batch log says what happened")
    }

    @Test("on disk: settling an interrupted batch leaves the skipped rows exactly as they were")
    func skipSurvivesSettleOnDisk() throws {
        let root = Self.tempDir("settle")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("batch-skip")
        var p = plan(dir.path, [entry(.ready, "a.mov"), entry(.preparing, "b.mov"), entry(.pending, "c.mov")])
        _ = p.skipEntry(id: p.entries[1].id, note: note)
        try ArchiveAngelPlanStore.save(p)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)],
                                              ofItemAtPath: p.planURL.path)

        _ = ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root)

        let after = try ArchiveAngelPlanStore.load(batchDir: dir.path)
        #expect(after.status == .ready)
        #expect(after.entries[1].status == .skipped)
        #expect(after.entries[2].status == .failed, "the never-prepared row still settles as failed (GH #177)")
        #expect(after.skippedCount == 1)
    }

    // MARK: - 4. Isolation — reservations and older plans on disk

    @Test("inFlightRecordIDs never reserves a skipped row — the record is free for the next batch")
    func skippedRowsAreNotReserved() throws {
        let root = Self.tempDir("inflight")
        defer { try? FileManager.default.removeItem(at: root) }

        // A LIVE preparing batch (plan.json just written) with a skipped row.
        var live = plan(root.appendingPathComponent("batch-live").path,
                        [entry(.ready, "a.mov"), entry(.pending, "b.mov"), entry(.preparing, "c.mov")])
        _ = live.skipEntry(id: live.entries[2].id, note: note)
        try ArchiveAngelPlanStore.save(live)
        // A reviewable batch that also carries a skipped row.
        var done = plan(root.appendingPathComponent("batch-ready").path,
                        [entry(.ready, "d.mov"), entry(.pending, "e.mov")], status: .ready)
        _ = done.skipEntry(id: done.entries[1].id, note: note)
        try ArchiveAngelPlanStore.save(done)

        let ids = ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root)
        #expect(ids.contains(live.entries[0].id) && ids.contains(live.entries[1].id),
                "a live job's ready and pending rows stay reserved")
        #expect(!ids.contains(live.entries[2].id), "the skipped row is released")
        #expect(ids.contains(done.entries[0].id))
        #expect(!ids.contains(done.entries[1].id), "…in a ready batch too")
    }

    @Test("a plan written by an older build — no skip fields at all — still loads")
    func olderPlanStillLoads() throws {
        let dir = Self.tempDir("oldbuild")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = plan(dir.path, [entry(.ready, "a.mov"), entry(.failed, "b.mov")], status: .ready)
        p.report = ArchiveAngelPlan.Report(promotedOriginals: 1, accessCopies: 1)
        try ArchiveAngelPlanStore.save(p)

        // Strip every field this feature added, the way a pre-2026-09-13
        // plan.json looks on disk.
        let url = dir.appendingPathComponent(ArchiveAngelPlan.planFilename)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var rows = json["entries"] as! [[String: Any]]
        for i in rows.indices { rows[i].removeValue(forKey: "skippedAt"); rows[i].removeValue(forKey: "skipNote") }
        json["entries"] = rows
        var report = json["report"] as! [String: Any]
        report.removeValue(forKey: "skippedByUser")
        json["report"] = report
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let loaded = try ArchiveAngelPlanStore.load(batchDir: dir.path)
        #expect(loaded.entries.count == 2)
        #expect(loaded.entries.allSatisfy { $0.skippedAt == nil && $0.skipNote == nil })
        #expect(loaded.skippedCount == 0)
        #expect(loaded.report?.skippedByUser == nil)
        #expect(loaded.report?.summary.contains("skipped") == false, "an old report says nothing about skips")
    }

    // MARK: - 5. Sensors

    @Test("SENSOR: a skipped entry's partial companions leave the buffer; its neighbours and the plan do not")
    func skippedEntryBufferIsReclaimed() throws {
        let fm = FileManager.default
        let dir = Self.tempDir("buffer")
        defer { try? fm.removeItem(at: dir) }
        var p = plan(dir.path, [entry(.preparing, "b.mov"), entry(.ready, "a.mov")])
        try ArchiveAngelPlanStore.save(p)

        // Half-written companions, exactly as a cancelled transcode leaves them.
        for e in p.entries {
            let folder = dir.appendingPathComponent(e.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 2_048).write(to: folder.appendingPathComponent("partial.vs.archive.mov"))
        }
        let skippedFolder = dir.appendingPathComponent(p.entries[0].id.uuidString)
        let keptFolder = dir.appendingPathComponent(p.entries[1].id.uuidString)
        #expect(fm.fileExists(atPath: skippedFolder.path))

        _ = p.skipEntry(id: p.entries[0].id, note: note)
        ArchiveAngelPlanStore.removeEntryFolder(p, entry: p.entries[0])   // what the job does after the sub-job unwinds
        try ArchiveAngelPlanStore.save(p)

        #expect(!fm.fileExists(atPath: skippedFolder.path), "the skipped row's buffer space is reclaimed")
        #expect(fm.fileExists(atPath: keptFolder.path), "…and nobody else's is touched")
        let reloaded = try ArchiveAngelPlanStore.load(batchDir: dir.path)
        #expect(reloaded.entries[0].status == .skipped, "the batch folder and its plan survive")
        #expect(reloaded.entries.count == 2, "a skipped row stays VISIBLE — Rick wants to look at them later")
    }

    @MainActor
    @Test("SENSOR: a user skip never looks like a failure — distinct status, icon and colour")
    func skipNeverLooksLikeFailure() {
        #expect(ArchiveAngelPlan.EntryStatus.skipped.rawValue != ArchiveAngelPlan.EntryStatus.failed.rawValue)
        #expect(ArchiveAngelDetailView.icon(.skipped) != ArchiveAngelDetailView.icon(.failed))
        #expect(ArchiveAngelDetailView.color(.skipped) != Color.red)
        #expect(ArchiveAngelReviewSheet.settledSymbol(.skipped) != ArchiveAngelReviewSheet.settledSymbol(.failed))
        #expect(ArchiveAngelReviewSheet.settledColor(.skipped) != Color.red)
        #expect(!ArchiveAngelPlan.EntryStatus.skipped.isUnsettled, "a skip is a settled decision")
        #expect(!ArchiveAngelPlan.EntryStatus.skipped.isSkippable, "…and cannot be skipped twice")
    }

    @Test("SENSOR: the derivative hint reads the filename only — no catalog, no new plumbing")
    func derivativeHintFromFilename() {
        #expect(entry(.pending, "Clip 08.vs.edit.mov").derivativeOfStem == "Clip 08")
        #expect(entry(.pending, "1993_Cape_balanced.mov").derivativeOfStem == "1993_Cape")
        #expect(entry(.pending, "1993_Cape.mov").derivativeOfStem == nil)
    }

    // MARK: - 6. Scale

    @Test("SCALE: the entry-status walk over a 100k-row plan stays linear and runs off the main actor")
    func statusWalkIsLinearOffMain() async {
        let rows: [ArchiveAngelPlan.Entry] = (0..<100_000).map { i in
            entry(i % 7 == 0 ? .skipped : (i % 3 == 0 ? .ready : .pending), "f\(i).mov")
        }
        let p = plan("/tmp/scale", rows)
        let elapsed = await Task.detached(priority: .utility) { () -> Double in
            #expect(!Thread.isMainThread, "the walk must not run on the main actor")
            let t0 = Date()
            let toPrepare = p.entries.reduce(into: 0) { $0 += ($1.loopAction == .prepare ? 1 : 0) }
            let skipped = p.skippedCount
            let ready = p.readyCount
            #expect(skipped == 14_286)
            #expect(ready + skipped + toPrepare == 100_000, "every row is accounted for exactly once")
            return Date().timeIntervalSince(t0)
        }.value
        #expect(elapsed < 1.0, "100k rows in \(String(format: "%.3f", elapsed))s — budget 1.0s")
    }

    // MARK: helpers

    private static func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_skip_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
