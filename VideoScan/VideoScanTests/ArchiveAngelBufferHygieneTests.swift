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
//               .discarded on disk even when the removal fails; an
//               unreadable current plan is REFUSED (never the snapshot); a
//               failed save writes no ledger line and a retry writes each
//               line once; a symlink alias is never a batch; a companion
//               record is retired only for a file confirmed gone (codex
//               review 2026-09-20 #1–#4, #10).
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

    @Test("a ready batch with no ready rows, nothing pending and only its plan.json is NOT a waiting batch (Rick 2026-09-22: '1 prepared batch (805 B) is waiting… nothing prepared')")
    func emptyReadyBatchIsNotWaiting() {
        let hollow = plan("batch-2026-09-22T12-00-00", .ready,
                          rows: [entry(.skipped), entry(.failed, failure: "boom")], createdDaysAgo: 0.2)
        let r = H.report(plans: [hollow], bytesOf: { _ in 805 }, isLive: { _ in false }, now: now)
        #expect(r.batches.isEmpty && r.isEmpty, "nothing to decide → no card")
        // A hollow batch that still holds real bytes is shown, so its files can be cleared.
        let heavy = H.report(plans: [hollow], bytesOf: { _ in 4_000_000_000 }, isLive: { _ in false }, now: now)
        #expect(heavy.waitingCount == 1)
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
        // One ready row: an EMPTY ready batch is no longer a card at all
        // (emptyReadyBatchIsNotWaiting), and this test is about the clock.
        var exactly = plan("batch-d", .ready, rows: [entry(.ready)], createdDaysAgo: 14)
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

    @Test("the card's file list (Rick 2026-09-20): every entry with a plain-words status, its size, the companions that exist; the summary line; ≤ 12 files opens by default")
    func entryListAndSummary() {
        var ready = entry(.ready); ready.sizeBytes = 4_200_000_000
        ready.set(.verifyAudio, .done); ready.set(.balanceAudio, .done, output: "x/b.mov")
        ready.set(.accessCopy, .done, output: "x/a.mov"); ready.set(.losslessCopy, .skipped, note: "off")
        var readyOriginalOnly = entry(.ready); readyOriginalOnly.set(.verifyAudio, .done)
        var doneButNoPath = entry(.ready); doneButNoPath.set(.accessCopy, .done)   // no output: not a companion
        let skipped = entry(.skipped), promoted = entry(.promoted), pending = entry(.pending)
        let waiting = entry(.failed, failure: ArchiveAngelPlan.bufferShortNote(need: 100, free: 10))
        let broken = entry(.failed, failure: "Transcode failed: exit code 69. Invalid data found when processing input")
        var brokenStep = entry(.failed); brokenStep.set(.accessCopy, .failed, note: "ffmpeg exit 1")
        let unexplained = entry(.failed)
        let p = plan("batch-list", .ready, rows: [ready, readyOriginalOnly, doneButNoPath, skipped, promoted, pending, waiting, broken, brokenStep, unexplained],
                     createdDaysAgo: 1)

        let lines = H.entryLines(p)
        #expect(lines.map(\.id) == p.entries.map(\.id), "plan order, every entry")
        #expect(lines[0].statusText == "Ready to review" && lines[0].sizeBytes == 4_200_000_000)
        #expect(lines[0].companions == ["balanced", "access"], "\(lines[0].companions)")
        #expect(lines[1].companions.isEmpty, "verify leaves no file")
        #expect(lines[2].companions.isEmpty, "a done step with no output path is not a file in the buffer")
        #expect(lines[3].statusText == "Skipped by you" && lines[4].statusText == "Promoted" && lines[5].statusText == "Pending")
        #expect(lines[6].statusText == "Waiting for buffer space" && lines[6].isBufferShort)
        #expect(lines[7].statusText == "Failed: Transcode failed: exit code 69", "\(lines[7].statusText)")
        #expect(lines[8].statusText == "Failed: ffmpeg exit 1", "a step's note when the row has no reason")
        #expect(lines[9].statusText == "Failed: no reason recorded")
        #expect(H.shortReason(String(repeating: "x", count: 80)).count == 58 && H.shortReason("  ") == "no reason recorded")
        #expect(H.summaryText(p) == "3 ready · 1 skipped · 1 promoted · 1 waiting for buffer space · 3 failed · 1 pending")
        #expect(H.summaryText(plan("batch-plain", .ready, rows: [ready, ready, skipped], createdDaysAgo: 1)) == "2 ready · 1 skipped · 0 promoted")

        let r = H.report(plans: [p], bytesOf: { _ in 1 }, isLive: { _ in false }, now: now)
        #expect(r.batches[0].entries == lines && r.batches[0].summary == H.summaryText(p))
        #expect(r.batches[0].expandsByDefault, "10 files: open")
        let big = plan("batch-big", .ready, rows: (0..<13).map { _ in entry(.ready) }, createdDaysAgo: 1)
        #expect(!H.report(plans: [big], bytesOf: { _ in 1 }, isLive: { _ in false }, now: now).batches[0].expandsByDefault, "13 files: closed")
    }

    @Test("#9 a report carries the refresh that made it; an older scan never publishes over a newer one")
    func generationGuard() {
        var first = H.report(plans: [], bytesOf: { _ in 0 }, isLive: { _ in false }, now: now)
        first.generation = 3
        var late = first; late.generation = 2
        var next = first; next.generation = 4
        #expect(!late.isNewer(than: first), "an older scan finishing late is dropped")
        #expect(!first.isNewer(than: first), "the same scan twice is not newer")
        #expect(next.isNewer(than: first))
        #expect(H.Report.empty.generation == 0 && next.isNewer(than: .empty))
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
        #expect(out.bytesFreed == 0, "no figure handed in: the walk is the removal task's, never the main actor's (#10)")
        let removal = try #require(await out.removal?.value)
        #expect(removal.removed, "the detached removal succeeded: \(removal.failure ?? "")")
        #expect(removal.bytesFreed >= 5 * 2_048, "five row folders plus plan.json, walked off-main: \(removal.bytesFreed)")
        #expect(removal.companionsRetired == 2, "retired AFTER the removal, files confirmed gone (#4)")
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
        let comp = companion(plan.batchDir + "/\(a.id.uuidString)/a.mov.vs.archive.mov", of: a)
        model.records = [a, comp]
        struct Boom: Error {}
        let out = model.clearArchiveAngelBatch(plan, reason: "test", remove: { _ in throw Boom() })
        #expect(out.cleared && out.refusal == nil, "scheduled — the failure is reported by the task")
        let removal = try #require(await out.removal?.value)
        #expect(!removal.removed && removal.failure != nil, "the removal failed")
        #expect(FileManager.default.fileExists(atPath: plan.batchDir))
        #expect(out.rowsReturned == 1)
        // #4: the companion's file is still there, so its record survives
        // and earns no copyDeleted line.
        #expect(removal.companionsRetired == 0 && !comp.isPurged, "a record is retired only for a file confirmed gone")
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }.isEmpty, "no copyDeleted for a surviving file")
        try await Task.sleep(nanoseconds: 300_000_000)   // the console flushes every 150 ms
        #expect(model.dashboard.consoleLines.contains { $0.contains("kept 1 companion record(s) of batch-durable") }, "the survivor is logged: \(model.dashboard.consoleLines.suffix(6))")
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
        #expect(out.cleared && out.rowsReturned == 0)
        #expect(out.bytesFreed == 3_700_000_000, "the caller's measurement is used, not a re-walk")
        let removal = try #require(await out.removal?.value)
        #expect(removal.removed && removal.bytesFreed == 3_700_000_000 && removal.companionsRetired == 1)
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
        #expect(await out3.removal?.value.removed == true)
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
        let compA = companion(one.batchDir + "/\(a.id.uuidString)/a.mov.vs.archive.mov", of: a)
        let compC = companion(three.batchDir + "/\(c.id.uuidString)/c.mov.vs.archive.mov", of: c)
        model.records.append(contentsOf: [compA, compC])
        let all = model.clearArchiveAngelBatches([one, two, three], bytes: [one.batchID: 10, three.batchID: 20], reason: "Clear all")
        let outs = all.outcomes
        #expect(outs.map(\.cleared) == [true, false, true])
        #expect(outs[1].refusal == .promoting)
        #expect(outs[0].bytesFreed == 10 && outs[2].bytesFreed == 20)
        for out in outs { _ = await out.removal?.value }
        #expect(!FileManager.default.fileExists(atPath: one.batchDir) && FileManager.default.fileExists(atPath: two.batchDir)
                && !FileManager.default.fileExists(atPath: three.batchDir))
        #expect(await clearedLines(model).map(\.recordID) == [a.id])
        // #10: ONE companion pass for the whole Clear all, after every removal.
        #expect(outs.allSatisfy { ($0.removal == nil) || true })
        #expect(await all.finished.value == 2, "both companions, in the single pass")
        #expect(compA.isPurged && compC.isPurged)
        for out in outs { #expect(await out.removal?.value.companionsRetired ?? 0 == 0, "no per-batch pass inside Clear all") }
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

        #expect(await first.removal?.value.removed == true)
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
        #expect(await third.removal?.value.removed == true)

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


    // MARK: - codex review 2026-09-20 (#1, #2, #3)

    @Test("#1 REFUSAL: display, then corrupt the current plan.json, then Clear — no ledger line, no save, no removal, one log line")
    func unreadableCurrentPlanIsRefusedNotFallenBackTo() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygunreadable")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov")
        let plan = try makeBatch(sb, name: "batch-corrupt", status: .ready, rows: [entry(a, .ready)])
        let comp = companion(plan.batchDir + "/\(a.id.uuidString)/a.mov.vs.archive.mov", of: a)
        model.records = [a, comp]
        let displayed = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)   // what the card/sheet holds
        try Data("{ not json".utf8).write(to: plan.planURL)                       // …then the disk goes bad

        let out = model.clearArchiveAngelBatch(displayed, reason: "test")
        guard case .unreadable(let why)? = out.refusal else { Issue.record("\(String(describing: out.refusal))"); return }
        #expect(!why.isEmpty)
        #expect(!out.cleared && !out.removalScheduled && out.removal == nil && out.rowsReturned == 0)
        #expect(try Data(contentsOf: plan.planURL) == Data("{ not json".utf8), "nothing was saved over it")
        #expect(FileManager.default.fileExists(atPath: comp.fullPath) && !comp.isPurged)
        #expect(await clearedLines(model).isEmpty, "the stale snapshot authorised nothing")
        #expect(!ArchiveAngelLiveBatches.isLive(plan.batchDir))
        try await Task.sleep(nanoseconds: 300_000_000)
        let lines = model.dashboard.consoleLines.filter { $0.contains("not clearing batch-corrupt") }
        #expect(lines.count == 1 && lines[0].contains("can't be read"), "\(lines)")
        // A missing plan.json (the folder exists) is the same refusal.
        try FileManager.default.removeItem(at: plan.planURL)
        let again = model.clearArchiveAngelBatch(displayed, reason: "test")
        if case .unreadable = again.refusal {} else { Issue.record("\(String(describing: again.refusal))") }
        #expect(FileManager.default.fileExists(atPath: plan.batchDir))
    }

    @Test("#2 a failed plan save is an explicit error: no ledger line, no companion retired, no removal; the retry writes ONE line per row")
    func failedSaveThenRetryWritesEachLineOnce() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygsavefail")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = original("a.mov"), b = original("b.mov")
        let plan = try makeBatch(sb, name: "batch-savefail", status: .ready, rows: [entry(a, .ready), entry(b, .ready)])
        let comp = companion(plan.batchDir + "/\(a.id.uuidString)/a.mov.vs.archive.mov", of: a)
        model.records = [a, b, comp]
        let fm = FileManager.default
        // A read-only batch folder: the atomic save cannot create its temp file.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: plan.batchDir)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.batchDir) }

        let failed = model.clearArchiveAngelBatch(plan, reason: "test")
        #expect(failed.refusal == nil && failed.error != nil && !failed.cleared, "\(String(describing: failed.error))")
        #expect(failed.rowsReturned == 0 && !failed.removalScheduled && failed.removal == nil)
        #expect(!comp.isPurged && fm.fileExists(atPath: comp.fullPath))
        #expect(try ArchiveAngelPlanStore.load(batchDir: plan.batchDir).status == .ready, "still open on disk")
        #expect(await clearedLines(model).isEmpty, "no half-skip was recorded for a decision that did not persist")
        #expect(!ArchiveAngelLiveBatches.isLive(plan.batchDir))

        // Retry once the disk is writable again.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.batchDir)
        let retry = model.clearArchiveAngelBatch(plan, reason: "test")
        #expect(retry.cleared && retry.error == nil && retry.rowsReturned == 2)
        let removal = try #require(await retry.removal?.value)
        #expect(removal.removed && removal.companionsRetired == 1)
        #expect(comp.isPurged)
        let lines = await clearedLines(model)
        #expect(lines.count == 2 && Set(lines.map(\.recordID)) == [a.id, b.id], "exactly one line per ready row: \(lines.map(\.filename))")
        #expect(model.archiveAngelAttention.summary(recordID: a.id, contentKey: "").timesCleared == 1)
        #expect(!fm.fileExists(atPath: plan.batchDir), "the retry's removal landed")
    }

    @Test("#3 a symlink alias to a LIVE batch is refused through the real Clear: no plan written through the alias, no ledger; scanBatches ignores it")
    func aliasToALiveBatchIsRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygalias")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let fm = FileManager.default
        let a = original("a.mov")
        model.records = [a]
        let live = try makeBatch(sb, name: "batch-live", status: .ready, rows: [entry(a, .ready)])
        let buffer = URL(fileURLWithPath: live.batchDir).deletingLastPathComponent()
        let alias = buffer.appendingPathComponent("batch-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: live.batchDir))
        // The attack: a plan loaded THROUGH the alias carries the alias path.
        let viaAlias = try ArchiveAngelPlanStore.load(batchDir: alias.path)
        #expect(viaAlias.batchDir == alias.path && viaAlias.status == .ready, "fixture: readable through the alias")
        ArchiveAngelLiveBatches.begin(live.batchDir)
        defer { ArchiveAngelLiveBatches.end(live.batchDir) }
        #expect(ArchiveAngelLiveBatches.isLive(alias.path), "liveness is keyed on the canonical folder")

        let out = model.clearArchiveAngelBatch(viaAlias, reason: "test")
        guard case .notABatchFolder(let why)? = out.refusal else { Issue.record("\(String(describing: out.refusal))"); return }
        #expect(why.contains("symlink"), Comment(rawValue: why))
        #expect(!out.cleared && out.removal == nil && out.rowsReturned == 0)
        #expect(try ArchiveAngelPlanStore.load(batchDir: live.batchDir).status == .ready, "the live plan was not written through the alias")
        #expect(fm.fileExists(atPath: live.batchDir) && fm.fileExists(atPath: alias.path))
        #expect(await clearedLines(model).isEmpty)

        // Not live either: still refused — an alias is never a batch.
        ArchiveAngelLiveBatches.end(live.batchDir)
        let idle = model.clearArchiveAngelBatch(viaAlias, reason: "test")
        if case .notABatchFolder = idle.refusal {} else { Issue.record("\(String(describing: idle.refusal))") }
        ArchiveAngelLiveBatches.begin(live.batchDir)

        // scanBatches never lists it, and says so once.
        var logged: [String] = []
        let scan = ArchiveAngelPlanStore.scanBatches(bufferRoot: buffer, log: { logged.append($0) })
        #expect(scan.plans.map(\.batchDir) == [live.batchDir], "\(scan.plans.map(\.batchDir))")
        #expect(scan.unreadable.isEmpty)
        #expect(logged.count == 1 && logged[0].contains("batch-alias") && logged[0].contains("symlink"), "\(logged)")
        _ = ArchiveAngelPlanStore.scanBatches(bufferRoot: buffer, log: { logged.append($0) })
        #expect(logged.count == 1, "once per session")
        // The whole-batch settle walks the same scan: the alias is untouched.
        #expect(ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: buffer).isEmpty)
        #expect(fm.fileExists(atPath: alias.path))
    }

    @Test("#3 a symlink alias to a batch OUTSIDE the buffer is refused; the external batch keeps its plan and folder")
    func aliasToAnExternalBatchIsRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygalias2")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let fm = FileManager.default
        let a = original("a.mov")
        model.records = [a]
        // A sentinel batch somewhere else entirely.
        let elsewhere = sb.root.appendingPathComponent("elsewhere/batch-external", isDirectory: true)
        try fm.createDirectory(at: elsewhere.appendingPathComponent(a.id.uuidString), withIntermediateDirectories: true)
        try Data(count: 2_048).write(to: elsewhere.appendingPathComponent("\(a.id.uuidString)/a.mov.vs.archive.mov"))
        var external = ArchiveAngelPlan(batchDir: elsewhere.path, requestedCount: 1, makeLossless: false, entries: [entry(a, .ready)])
        external.status = .ready
        try ArchiveAngelPlanStore.save(external)
        let buffer = sb.root.appendingPathComponent("buffer", isDirectory: true)
        try fm.createDirectory(at: buffer, withIntermediateDirectories: true)
        let alias = buffer.appendingPathComponent("batch-ext")
        try fm.createSymbolicLink(at: alias, withDestinationURL: elsewhere)
        let viaAlias = try ArchiveAngelPlanStore.load(batchDir: alias.path)

        let out = model.clearArchiveAngelBatch(viaAlias, reason: "test")
        if case .notABatchFolder = out.refusal {} else { Issue.record("\(String(describing: out.refusal))") }
        #expect(!out.cleared && out.removal == nil)
        #expect(try ArchiveAngelPlanStore.load(batchDir: elsewhere.path).status == .ready)
        #expect(fm.fileExists(atPath: elsewhere.appendingPathComponent("\(a.id.uuidString)/a.mov.vs.archive.mov").path))
        #expect(await clearedLines(model).isEmpty)
        #expect(ArchiveAngelPlanStore.scanBatches(bufferRoot: buffer, log: { _ in }).plans.isEmpty)

        // The store's guard on its own: the symlink, and a canonical parent
        // that is not the buffer even when the lexical one is.
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.isASymlink(alias.standardizedFileURL.path)) {
            try ArchiveAngelPlanStore.checkBatchFolder(alias.path, bufferRoot: buffer)
        }
        // A real batch reached THROUGH an alias of the buffer: the lexical
        // parent is not the buffer, so it is refused too — lexical and
        // canonical must both agree (the scan only ever yields <root>/batch-…).
        let bufferAlias = sb.root.appendingPathComponent("buffer-alias")
        try fm.createSymbolicLink(at: bufferAlias, withDestinationURL: buffer)
        let real = buffer.appendingPathComponent("batch-real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.self) {
            try ArchiveAngelPlanStore.checkBatchFolder(bufferAlias.appendingPathComponent("batch-real").path, bufferRoot: buffer)
        }
        #expect(throws: Never.self) { try ArchiveAngelPlanStore.checkBatchFolder(real.path, bufferRoot: buffer) }
        #expect(throws: Never.self) {
            // The same real folder named through a root whose own path holds a
            // symlink (/var → /private/var): lexical and canonical still agree.
            try ArchiveAngelPlanStore.checkBatchFolder(bufferAlias.appendingPathComponent("batch-real").path, bufferRoot: bufferAlias)
        }
        // …and a folder under the aliased parent whose REAL parent is elsewhere is not.
        let otherAlias = sb.root.appendingPathComponent("other-alias")
        try fm.createSymbolicLink(at: otherAlias, withDestinationURL: sb.root.appendingPathComponent("elsewhere"))
        #expect(throws: ArchiveAngelPlanStore.BatchFolderError.self) {
            try ArchiveAngelPlanStore.checkBatchFolder(otherAlias.appendingPathComponent("batch-external").path, bufferRoot: buffer)
        }
        #expect(ArchiveAngelPlanStore.isSymlink(alias.path) && !ArchiveAngelPlanStore.isSymlink(real.path)
                && !ArchiveAngelPlanStore.isSymlink(buffer.appendingPathComponent("missing").path))
    }

    @Test("SCALE #10: Clear all over a 100k-record catalog and 6 batches with no sizes handed in — the synchronous part stays under 400 ms, one companion pass")
    func clearAllBudgetOnALargeCatalog() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hygbudget")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        var plans: [ArchiveAngelPlan] = []
        var comps: [VideoRecord] = []
        for i in 0..<6 {
            let o = original("o\(i).mov")
            let p = try makeBatch(sb, name: "batch-\(i)", status: i % 2 == 0 ? .ready : .promoted,
                                  rows: (0..<8).map { _ in entry(original("r.mov"), i % 2 == 0 ? .ready : .promoted) })
            plans.append(p)
            comps.append(companion(p.batchDir + "/\(o.id.uuidString)/o\(i).mov.vs.archive.mov", of: o))
        }
        var records: [VideoRecord] = (0..<100_000).map { i in
            let r = VideoRecord()
            r.filename = "f\(i).mov"; r.fullPath = "/Volumes/Big/tapes/\(i % 97)/f\(i).mov"; r.sizeBytes = 1
            return r
        }
        records.append(contentsOf: comps)
        model.records = records

        let clock = ContinuousClock()
        var all: ArchiveAngelBatchClearAllOutcome?
        let sync = clock.measure {
            all = model.clearArchiveAngelBatches(plans, reason: "Clear all")   // no bytes: the walks are off-main
        }
        let outcome = try #require(all)
        let refusals = outcome.outcomes.map { String(describing: $0.refusal) }
        #expect(outcome.outcomes.filter { !$0.cleared }.isEmpty, "\(refusals)")
        #expect(sync < .milliseconds(400), "the verb's synchronous part (6 plan reads + 3 fsync'd saves, no record walk): \(sync)")
        let total = await clock.measure { _ = await outcome.finished.value }
        #expect(sync + total < .seconds(5), "6 removals + one pass over 100k records: \(sync + total)")
        #expect(await outcome.finished.value == 6, "every companion, in the one pass")
        for out in outcome.outcomes {
            let r = try #require(await out.removal?.value)
            #expect(r.removed && r.bytesFreed >= 8 * 2_048 && r.companionsRetired == 0, "measured off-main; retired in the shared pass")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let passes = model.dashboard.consoleLines.filter { $0.contains("retired 1 catalogued companion record(s) of batch-") }
        #expect(passes.count == 6, "one line per batch from ONE pass — and no per-batch scan: \(passes.count)")
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
