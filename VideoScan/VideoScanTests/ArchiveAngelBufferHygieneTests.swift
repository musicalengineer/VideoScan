// ArchiveAngelBufferHygieneTests.swift
// Archive Angel curation Phase 2 — buffer hygiene (Rick 2026-09-19: 82 GB
// of prepared batches on a disk with 11 GB free; "NEVER auto-clear; old
// batches become this prompt").
//
// Five dimensions (project checklist):
//   LOGIC     — the report's classification table, the 14-day flag, the
//               totals, live/promoting rows without Clear, the headline /
//               row / banner text; the clear verb's ledger, plan, companion
//               and folder effects.
//   SCALE     — 200 synthetic plans classified under 50 ms (injected sizes).
//   ISOLATION — temp dirs only: sandbox model, sandbox ledger, sandbox
//               batch folders; never the real buffer or App Support.
//   SENSOR    — a skipped / promoted row NEVER gets an angelCleared line; a
//               live batch is refused with its folder intact; the plan is
//               .discarded on disk even when the removal fails.
//   (MEDIA MATRIX does not apply — no media file is opened.)

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The pure report

@Suite("Archive Angel — buffer hygiene report (curation Phase 2)")
struct ArchiveAngelBufferHygieneReportTests {

    typealias H = ArchiveAngelBufferHygiene
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // a fixed clock

    private func entry(_ status: ArchiveAngelPlan.EntryStatus, failure: String? = nil) -> ArchiveAngelPlan.Entry {
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/v/x.mov", filename: "x.mov", sizeBytes: 1_000,
                                       durationSeconds: 3_600, score: 40, evidence: [], proposedName: "x.mov",
                                       proposedDate: "1993", status: status)
        e.failure = failure
        return e
    }

    private func plan(_ name: String, _ status: ArchiveAngelPlan.Status, rows: [ArchiveAngelPlan.Entry],
                      createdDaysAgo: Double) -> ArchiveAngelPlan {
        var p = ArchiveAngelPlan(createdAt: now.addingTimeInterval(-createdDaysAgo * day),
                                 batchDir: "/tmp/never-touched/\(name)", requestedCount: rows.count,
                                 makeLossless: false, entries: rows)
        p.status = status
        return p
    }

    @Test("Rick's buffer on 2026-09-19: two waiting batches, two promoted leftovers, one live — kinds, totals, headline")
    func ricksBuffer() {
        let waitingParked = entry(.failed, failure: ArchiveAngelPlan.bufferShortNote(need: 100, free: 10))
        let big = plan("batch-2026-09-15T18-18-14", .ready,
                       rows: (0..<6).map { _ in entry(.ready) } + (0..<4).map { _ in entry(.skipped) }, createdDaysAgo: 4.5)
        let empty = plan("batch-2026-09-15T20-03-09", .ready,
                         rows: (0..<10).map { _ in waitingParked }, createdDaysAgo: 4.2)
        let promotedA = plan("batch-2026-09-12T10-00-00", .promoted,
                             rows: [entry(.promoted), entry(.promoted), entry(.failed, failure: "boom")], createdDaysAgo: 7.1)
        let promotedB = plan("batch-2026-09-13T10-00-00", .promoted, rows: [entry(.promoted), entry(.failed, failure: "boom")], createdDaysAgo: 6)
        let promotedClean = plan("batch-2026-09-14T10-00-00", .promoted, rows: [entry(.promoted)], createdDaysAgo: 5)
        let tonight = plan("batch-2026-09-19T20-49-03", .preparing, rows: [entry(.ready), entry(.preparing)], createdDaysAgo: 0.1)
        let sizes: [String: Int64] = [
            big.batchID: 70_700_000_000, empty.batchID: 0, promotedA.batchID: 3_700_000_000,
            promotedB.batchID: 2_900_000_000, promotedClean.batchID: 40_000, tonight.batchID: 4_000_000_000,
        ]
        let r = H.report(plans: [tonight, big, empty, promotedA, promotedB, promotedClean],
                         bytesOf: { sizes[$0.batchID] ?? 0 },
                         isLive: { $0.batchID == tonight.batchID },
                         now: now, diskFree: 11_000_000_000)

        #expect(r.batches.map(\.id) == [promotedA.batchID, promotedB.batchID, big.batchID, empty.batchID, tonight.batchID],
                "oldest first; a promoted batch holding only its plan.json is not listed")
        #expect(r.waitingCount == 2 && r.waitingBytes == 70_700_000_000)
        #expect(r.leftoverCount == 2 && r.leftoverBytes == 6_600_000_000)
        #expect(r.totalBytes == 81_300_000_000, "the live batch's bytes count toward the total")
        #expect(!r.isEmpty)

        let rows = Dictionary(uniqueKeysWithValues: r.batches.map { ($0.id, $0) })
        #expect(rows[big.batchID]?.kind == .waiting(ready: 6, pending: 0, skipped: 4, failed: 0))
        #expect(rows[empty.batchID]?.kind == .waiting(ready: 0, pending: 10, skipped: 0, failed: 0),
                "rows parked for buffer space are 'waiting', not failures")
        #expect(rows[promotedA.batchID]?.kind == .leftover(status: .promoted, rowsLeft: 1))
        #expect(rows[tonight.batchID]?.kind == .inProgress(what: "preparing"))
        #expect(rows[tonight.batchID]?.canClear == false && rows[tonight.batchID]?.isLive == true)
        #expect(rows[big.batchID]?.canClear == true && rows[big.batchID]?.canReview == true)
        #expect(rows[promotedA.batchID]?.canClear == true && rows[promotedA.batchID]?.canReview == false)
        #expect(rows[promotedA.batchID]?.clearLabel == "Free 3.7 GB")
        #expect(rows[big.batchID]?.clearLabel == "Clear")
        #expect(r.clearable.map(\.id) == [promotedA.batchID, promotedB.batchID, big.batchID, empty.batchID])
        #expect(r.clearableBytes == 77_300_000_000)

        // MediaBytes.display: one decimal only below 10 in a unit (70.7 GB reads "71 GB", Finder-style).
        #expect(r.headline == "2 prepared batches (71 GB) are waiting in the buffer, and 2 finished batches still hold 6.6 GB — the disk has 11 GB free. What next?")
        #expect(r.bannerText == "4 batches (77 GB) are waiting in the buffer — clear or promote them first?")
        #expect(rows[big.batchID]?.line(now: now).hasSuffix(" · 71 GB · 6 ready, 4 skipped · untouched 4 days") == true,
                "\(rows[big.batchID]?.line(now: now) ?? "")")
        #expect(rows[empty.batchID]?.line(now: now).contains("10 waiting for buffer space") == true)
        #expect(rows[promotedA.batchID]?.line(now: now).contains("promoted — files of 1 row left behind · untouched 7 days") == true)
        #expect(rows[tonight.batchID]?.line(now: now).contains("preparing now · untouched today") == true)
    }

    @Test("stale flag: 13 days is not stale, 14 is; plan.json's mtime wins over finishedAt / createdAt")
    func staleAt14Days() {
        let old = plan("batch-a", .ready, rows: [entry(.ready)], createdDaysAgo: 30)
        var finished = plan("batch-b", .ready, rows: [entry(.ready)], createdDaysAgo: 30)
        finished.finishedAt = now.addingTimeInterval(-13.9 * day)
        let touched = plan("batch-c", .ready, rows: [entry(.ready)], createdDaysAgo: 30)
        let r = H.report(plans: [old, finished, touched], bytesOf: { _ in 1 },
                         modifiedAt: { $0.batchID == "batch-c" ? now.addingTimeInterval(-2 * day) : nil },
                         isLive: { _ in false }, now: now)
        let rows = Dictionary(uniqueKeysWithValues: r.batches.map { ($0.id, $0) })
        #expect(rows["batch-a"]?.untouchedDays == 30 && rows["batch-a"]?.isStale == true)
        #expect(rows["batch-b"]?.untouchedDays == 13 && rows["batch-b"]?.isStale == false)
        #expect(rows["batch-c"]?.untouchedDays == 2 && rows["batch-c"]?.isStale == false)
        var exactly = plan("batch-d", .ready, rows: [], createdDaysAgo: 14)
        exactly.finishedAt = nil
        #expect(H.report(plans: [exactly], bytesOf: { _ in 1 }, isLive: { _ in false }, now: now).batches.first?.isStale == true)
    }

    @Test("a promoting batch is never clearable (live or not); a parked interrupted batch is, and reviews only with ready rows")
    func promotingAndParked() {
        let promoting = plan("batch-p", .promoting, rows: [entry(.ready)], createdDaysAgo: 1)
        let parkedEmpty = plan("batch-q", .preparing, rows: [entry(.pending), entry(.pending)], createdDaysAgo: 1)
        let parkedSome = plan("batch-r", .preparing, rows: [entry(.ready), entry(.pending)], createdDaysAgo: 1)
        let readyLive = plan("batch-s", .ready, rows: [entry(.ready)], createdDaysAgo: 1)
        let r = H.report(plans: [promoting, parkedEmpty, parkedSome, readyLive], bytesOf: { _ in 5_000_000 },
                         isLive: { $0.batchID == "batch-s" }, now: now)
        let rows = Dictionary(uniqueKeysWithValues: r.batches.map { ($0.id, $0) })
        #expect(rows["batch-p"]?.kind == .inProgress(what: "promoting") && rows["batch-p"]?.canClear == false)
        #expect(rows["batch-q"]?.kind == .parked(ready: 0, unfinished: 2))
        #expect(rows["batch-q"]?.canClear == true && rows["batch-q"]?.canReview == false)
        #expect(rows["batch-r"]?.kind == .parked(ready: 1, unfinished: 1) && rows["batch-r"]?.canReview == false,
                "a parked batch offers Clear only — the sheet is never handed unsettled rows")
        #expect(rows["batch-s"]?.kind == .inProgress(what: "promoting"), "a ready batch that is live is being promoted")
        #expect(r.waitingCount == 2, "parked batches are waiting; in-progress ones are not")
        #expect(H.detailText(.parked(ready: 1, unfinished: 1)) == "interrupted while preparing — 1 ready, 1 unfinished")
    }

    @Test("empty and leftover-only reports; the discarded-but-still-here case; singular grammar")
    func headlines() {
        #expect(H.report(plans: [], bytesOf: { _ in 0 }, isLive: { _ in false }, now: now) == .empty)
        #expect(H.Report.empty.isEmpty && H.Report.empty.headline.isEmpty && H.Report.empty.bannerText.isEmpty)
        let promoted = plan("batch-x", .promoted, rows: [entry(.promoted)], createdDaysAgo: 20)
        let discarded = plan("batch-y", .discarded, rows: [entry(.failed)], createdDaysAgo: 2)
        let r = H.report(plans: [promoted, discarded], bytesOf: { $0.batchID == "batch-x" ? 3_700_000_000 : 999_999 },
                         isLive: { _ in false }, now: now, diskFree: 11_000_000_000)
        #expect(r.batches.count == 1, "under the 1 MB floor is just a plan.json")
        #expect(r.isEmpty == false && r.waitingCount == 0 && r.leftoverCount == 1)
        #expect(r.headline == "1 finished batch still holds 3.7 GB in the buffer — the disk has 11 GB free. Free it?")
        #expect(r.bannerText == "1 batch (3.7 GB) is waiting in the buffer — clear or promote it first?")
        #expect(r.batches[0].isStale, "20 days")
        let d = H.report(plans: [discarded], bytesOf: { _ in 2_000_000 }, isLive: { _ in false }, now: now)
        #expect(d.batches[0].kind == .leftover(status: .discarded, rowsLeft: 1))
        #expect(H.detailText(.leftover(status: .discarded, rowsLeft: 0)) == "discarded — folder still here")
        #expect(H.headline(waitingCount: 1, waitingBytes: 70_700_000_000, leftoverCount: 0, leftoverBytes: 0, diskFree: nil)
                == "1 prepared batch (71 GB) is waiting in the buffer. What next?")
        #expect(H.detailText(.waiting(ready: 0, pending: 0, skipped: 0, failed: 0)) == "nothing prepared")
        #expect(H.detailText(.waiting(ready: 2, pending: 1, skipped: 0, failed: 3)) == "2 ready, 1 waiting for buffer space, 3 failed")
        #expect(H.untouchedText(0) == "untouched today" && H.untouchedText(1) == "untouched 1 day")
    }

    @Test("SCALE: 200 plans × 12 rows classified under 50 ms with injected sizes")
    func twoHundredPlans() {
        let statuses: [ArchiveAngelPlan.Status] = [.ready, .promoted, .discarded, .preparing, .promoting]
        let plans = (0..<200).map { i in
            plan("batch-\(i)", statuses[i % statuses.count],
                 rows: (0..<12).map { j in entry(j % 3 == 0 ? .ready : (j % 3 == 1 ? .skipped : .failed)) },
                 createdDaysAgo: Double(i % 40))
        }
        let clock = ContinuousClock()
        var report = H.Report.empty
        let elapsed = clock.measure {
            report = H.report(plans: plans, bytesOf: { Int64($0.requestedCount) * 10_000_000 }, isLive: { _ in false }, now: now)
        }
        #expect(report.batches.count == 200)
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
    }
}

// MARK: - The clear verb on a sandbox model

@Suite("Archive Angel — clearArchiveAngelBatch, the one clear verb", .serialized)
@MainActor
struct ArchiveAngelBufferHygieneClearTests {

    private func makeModel(_ sb: MasterArchiveTestSupport.Sandbox) throws -> VideoScanModel {
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        return model
    }

    private func original(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/LaCie/Family/\(name)"
        r.sizeBytes = 5_000
        return r
    }

    private func companion(_ path: String, of rec: VideoRecord) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.sizeBytes = 1_000
        r.derivedFrom = rec.id
        r.workspaceActive = true
        return r
    }

    private func entry(_ rec: VideoRecord, _ status: ArchiveAngelPlan.EntryStatus) -> ArchiveAngelPlan.Entry {
        .init(id: rec.id, sourcePath: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
              durationSeconds: 3_600, score: 40, evidence: [], proposedName: rec.filename, proposedDate: "1993",
              status: status)
    }

    /// A batch folder on disk under the sandbox with one companion file
    /// per row (2 KB each) and a saved plan.json.
    private func makeBatch(_ sb: MasterArchiveTestSupport.Sandbox, name: String, status: ArchiveAngelPlan.Status,
                           rows: [ArchiveAngelPlan.Entry]) throws -> ArchiveAngelPlan {
        let dir = sb.root.appendingPathComponent("buffer/\(name)", isDirectory: true)
        var plan = ArchiveAngelPlan(batchDir: dir.path, requestedCount: rows.count, makeLossless: false, entries: rows)
        plan.status = status
        for row in rows {
            let rowDir = dir.appendingPathComponent(row.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rowDir, withIntermediateDirectories: true)
            try Data(count: 2_048).write(to: rowDir.appendingPathComponent("\(row.filename).vs.archive.mov"))
        }
        try ArchiveAngelPlanStore.save(plan)
        return plan
    }

    private func clearedLines(_ model: VideoScanModel) async -> [MediaLedgerEvent] {
        await model.mediaLedger.waitForPendingWrites()
        return model.mediaLedger.allEvents().filter { $0.event == .angelCleared }
    }

    @Test("a ready batch: angelCleared for the READY rows only, plan .discarded, companions retired, folder gone, bytes reported")
    func clearsAReadyBatch() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygclear")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov"), b = original("b.mov"), skipped = original("s.mov"), promoted = original("p.mov"), failed = original("f.mov")
        var plan = try makeBatch(sb, name: "batch-2026-09-15T18-18-14", status: .ready,
                                 rows: [entry(a, .ready), entry(b, .ready), entry(skipped, .skipped),
                                        entry(promoted, .promoted), entry(failed, .failed)])
        let compA = companion(plan.batchDir + "/\(a.id.uuidString)/a.mov.vs.archive.mov", of: a)
        let compB = companion(plan.batchDir + "/\(b.id.uuidString)/b.mov.vs.archive.mov", of: b)
        let elsewhere = companion(sb.root.appendingPathComponent("buffer/batch-other/x/y.mov").path, of: a)
        model.records = [a, b, skipped, promoted, failed, compA, compB, elsewhere]
        plan = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)

        let out = model.clearArchiveAngelBatch(plan, reason: "test clear")
        #expect(out.cleared && out.refusal == nil && out.error == nil)
        #expect(out.rowsReturned == 2, "the two undecided rows")
        #expect(out.companionsRetired == 2)
        #expect(out.bytesFreed >= 5 * 2_048, "five row folders plus plan.json (walked — no bytes handed in): \(out.bytesFreed)")
        #expect(await out.removal?.value == true, "the detached removal succeeded")
        #expect(!ArchiveAngelLiveBatches.isLive(plan.batchDir))
        #expect(!FileManager.default.fileExists(atPath: plan.batchDir))
        #expect(compA.isPurged && compB.isPurged)
        #expect(!elsewhere.isPurged && !a.isPurged, "originals and other batches untouched")

        let lines = await clearedLines(model)
        #expect(Set(lines.map(\.recordID)) == [a.id, b.id], "\(lines.map(\.filename))")
        #expect(lines.allSatisfy { $0.batchID == "batch-2026-09-15T18-18-14" && $0.by == .rick })
        #expect(lines.first?.detail[MediaLedgerEvent.Detail.reason] == "test clear")
        #expect(model.archiveAngelAttention.summary(recordID: a.id, contentKey: "").timesCleared == 1, "the attention memory saw it")
        #expect(model.archiveAngelAttention.summary(recordID: skipped.id, contentKey: "").isNew, "SENSOR: a skipped row is already decided")
        #expect(model.archiveAngelAttention.summary(recordID: promoted.id, contentKey: "").isNew, "SENSOR: a promoted row is already decided")
    }

    @Test("the decision is durable: plan.json reads .discarded even when the folder removal fails")
    func planSavedBeforeRemoval() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygdurable")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov")
        let plan = try makeBatch(sb, name: "batch-durable", status: .ready, rows: [entry(a, .ready)])
        model.records = [a]
        struct Boom: Error {}
        let out = model.clearArchiveAngelBatch(plan, reason: "test", remove: { _ in throw Boom() })
        #expect(out.cleared && out.refusal == nil, "scheduled — the failure is reported by the task")
        #expect(await out.removal?.value == false, "the removal failed")
        #expect(FileManager.default.fileExists(atPath: plan.batchDir))
        #expect(out.rowsReturned == 1)
        let onDisk = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        #expect(onDisk.status == .discarded)
        #expect(onDisk.log.last?.contains("Cleared from the buffer — test; 1 undecided row(s) returned to the pool") == true, "\(onDisk.log)")
        #expect(onDisk.finishedAt != nil)
        #expect(await clearedLines(model).count == 1, "the ledger line was written before the removal was tried")
    }

    @Test("a promoted leftover: folder + companions go, NO ledger lines (its rows were decided), plan untouched")
    func clearsALeftover() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygleft")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let p = original("p.mov"), f = original("f.mov")
        let plan = try makeBatch(sb, name: "batch-promoted", status: .promoted, rows: [entry(p, .promoted), entry(f, .failed)])
        let leftover = companion(plan.batchDir + "/\(f.id.uuidString)/f.mov.vs.archive.mov", of: f)
        model.records = [p, f, leftover]

        let out = model.clearArchiveAngelBatch(plan, reason: "free the leftovers", bytes: 3_700_000_000)
        #expect(out.cleared && out.rowsReturned == 0 && out.companionsRetired == 1)
        #expect(out.bytesFreed == 3_700_000_000, "the caller's measurement is used, not a re-walk")
        #expect(await out.removal?.value == true)
        #expect(!FileManager.default.fileExists(atPath: plan.batchDir))
        #expect(leftover.isPurged)
        #expect(await clearedLines(model).isEmpty, "SENSOR: no half-skip for a decided batch")
    }

    @Test("refused: a live batch keeps its folder and writes nothing; so does a promoting plan")
    func refusesLiveAndPromoting() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hyglive")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov")
        let live = try makeBatch(sb, name: "batch-live", status: .ready, rows: [entry(a, .ready)])
        model.records = [a]
        ArchiveAngelLiveBatches.begin(live.batchDir)
        let out = model.clearArchiveAngelBatch(live, reason: "test")
        ArchiveAngelLiveBatches.end(live.batchDir)
        #expect(out.refusal == .live && !out.cleared && out.bytesFreed == 0 && out.rowsReturned == 0)
        #expect(FileManager.default.fileExists(atPath: live.planURL.path))
        #expect(try ArchiveAngelPlanStore.load(batchDir: live.batchDir).status == .ready, "untouched")

        let promoting = try makeBatch(sb, name: "batch-promoting", status: .promoting, rows: [entry(a, .ready)])
        let out2 = model.clearArchiveAngelBatch(promoting, reason: "test")
        #expect(out2.refusal == .promoting && FileManager.default.fileExists(atPath: promoting.planURL.path))
        #expect(await clearedLines(model).isEmpty)

        // Once the job has let go, the same batch clears.
        let out3 = model.clearArchiveAngelBatch(live, reason: "test")
        #expect(out3.cleared)
        #expect(await out3.removal?.value == true)
    }

    @Test("Clear all: every batch handed over is tried; a refusal does not stop the rest")
    func clearAll() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygall")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov"), b = original("b.mov"), c = original("c.mov")
        model.records = [a, b, c]
        let one = try makeBatch(sb, name: "batch-1", status: .ready, rows: [entry(a, .ready)])
        let two = try makeBatch(sb, name: "batch-2", status: .promoting, rows: [entry(b, .ready)])
        let three = try makeBatch(sb, name: "batch-3", status: .discarded, rows: [entry(c, .failed)])
        let outs = model.clearArchiveAngelBatches([one, two, three], bytes: [one.batchID: 10, three.batchID: 20], reason: "Clear all")
        #expect(outs.map(\.cleared) == [true, false, true])
        #expect(outs[1].refusal == .promoting)
        #expect(outs[0].bytesFreed == 10 && outs[2].bytesFreed == 20)
        for out in outs { _ = await out.removal?.value }
        #expect(!FileManager.default.fileExists(atPath: one.batchDir) && FileManager.default.fileExists(atPath: two.batchDir)
                && !FileManager.default.fileExists(atPath: three.batchDir))
        #expect(await clearedLines(model).map(\.recordID) == [a.id])
    }

    // MARK: - QA RED tests (2026-09-19 review of feature/angel-buffer-hygiene)

    @Test("QA RED: clearing the same plan snapshot twice writes ONE angelCleared line per row, not two (VideoScanModel+ArchiveAngelBufferHygiene.swift:80-90)")
    func secondClearOfAStaleSnapshotIsIdempotent() async throws {
        // The card keeps showing a cleared row until refreshAngelBatches() lands;
        // a second Clear (or the review sheet's Discard) hands the verb the SAME
        // .ready snapshot. The verb trusts it: lines again, and saveLogged →
        // AtomicFilePublish.write(createIntermediates: true) resurrects the
        // batch folder just to remove it again — and reports `cleared == true`.
        let sb = try MasterArchiveTestSupport.makeSandbox("hygtwice")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov")
        let plan = try makeBatch(sb, name: "batch-twice", status: .ready, rows: [entry(a, .ready)])
        model.records = [a]

        let first = model.clearArchiveAngelBatch(plan, reason: "first")
        #expect(first.cleared && first.rowsReturned == 1)

        // Before the removal lands the batch is busy (live); a tiny folder may
        // already be gone by now — either way nothing is written.
        let during = model.clearArchiveAngelBatch(plan, reason: "again — removal in flight")
        #expect(during.refusal == .live || during.refusal == .gone, "\(String(describing: during.refusal))")
        #expect(during.rowsReturned == 0 && !during.cleared && during.removal == nil)

        #expect(await first.removal?.value == true)
        #expect(!FileManager.default.fileExists(atPath: plan.batchDir))

        let second = model.clearArchiveAngelBatch(plan, reason: "second — stale snapshot")
        #expect(second.refusal == .gone)
        #expect(second.rowsReturned == 0, "a row already returned to the pool must not be returned again")
        #expect(second.cleared == false, "nothing was there to clear")
        #expect(second.removal == nil)
        #expect(!FileManager.default.fileExists(atPath: plan.batchDir), "the folder must not be resurrected")

        // A stale .ready snapshot of a batch whose plan.json already says
        // .discarded (an earlier removal failed): folder only, no second half-skip.
        let again = try makeBatch(sb, name: "batch-stale", status: .ready, rows: [entry(a, .ready)])
        var onDisk = again; onDisk.status = .discarded
        try ArchiveAngelPlanStore.save(onDisk)
        let third = model.clearArchiveAngelBatch(again, reason: "stale snapshot, decided on disk")
        #expect(third.cleared && third.rowsReturned == 0)
        #expect(await third.removal?.value == true)

        let lines = await clearedLines(model)
        #expect(lines.count == 1, "SENSOR: one half-skip per clear, got \(lines.count)")
        #expect(model.archiveAngelAttention.summary(recordID: a.id, contentKey: "").timesCleared == 1)
    }

    @Test("QA RED: the verb refuses a plan whose batchDir is not a batch-… folder (defense for the ONE delete entry point; ArchiveAngelPlan.swift:543)")
    func refusesAFolderThatIsNotABatch() throws {
        // No production caller builds such a plan today (scanBatches only yields
        // bufferRoot/batch-*), but this is THE entry point that deletes, and
        // removeBatchFolder is a bare removeItem(atPath:) with no guard.
        let sb = try MasterArchiveTestSupport.makeSandbox("hygguard")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let stranger = sb.root.appendingPathComponent("not-a-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let keep = stranger.appendingPathComponent("family-tape.mov")
        try Data(count: 4_096).write(to: keep)
        var plan = ArchiveAngelPlan(batchDir: stranger.path, requestedCount: 0, makeLossless: false, entries: [])
        plan.status = .promoted   // a "leftover": the verb goes straight to remove

        let out = model.clearArchiveAngelBatch(plan, reason: "test")
        #expect(out.removalScheduled == false && out.removal == nil && out.cleared == false)
        if case .notABatchFolder(let why)? = out.refusal { #expect(why.contains("not a batch-… folder")) } else { Issue.record("\(String(describing: out.refusal))") }
        #expect(FileManager.default.fileExists(atPath: keep.path), "a folder that is not batch-… must never be removed")

        // The store's guard on its own: name and parent both matter.
        let root = sb.root.appendingPathComponent("buffer", isDirectory: true)
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.self) {
            try ArchiveAngelPlanStore.checkBatchFolder(root.appendingPathComponent("elsewhere/batch-x").path, bufferRoot: root)
        }
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.self) {
            try ArchiveAngelPlanStore.checkBatchFolder("/", bufferRoot: root)
        }
        #expect(throws: Never.self) {
            try ArchiveAngelPlanStore.checkBatchFolder(root.appendingPathComponent("batch-2026-09-15T18-18-14/").path, bufferRoot: root)
        }
        var lines: [String] = []
        var bad = ArchiveAngelPlan(batchDir: root.appendingPathComponent("photos").path, requestedCount: 0, makeLossless: false)
        bad.status = .promoted
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.self) {
            try ArchiveAngelPlanStore.removeBatchFolder(bad, bufferRoot: root, log: { lines.append($0) })
        }
        #expect(lines.count == 1 && lines[0].contains("refused to remove"), "\(lines)")
    }

    @Test("ISOLATION: the sandbox batches live under the temp dir, never the real buffer; the session 'Later' set is process memory only")
    func isolation() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygiso")
        defer { sb.cleanup() }
        #expect(sb.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!ArchiveAngelPlanStore.defaultBufferRoot.path.contains("/Movies/VideoScan Buffer"))
        let session = ArchiveAngelHygieneSession()
        session.laterBatchIDs.insert("batch-x")
        #expect(session.laterBatchIDs == ["batch-x"])
        #expect(ArchiveAngelHygieneSession().laterBatchIDs.isEmpty, "nothing persisted between instances")
    }
}
