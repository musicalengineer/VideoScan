// JunkOutcomeAccountingTests.swift
// Design R6 / R7 (codex design review F6, F7, 2026-10-09): ONE outcome per
// requested file, including the ones refused before any disk work (an
// all-protected selection used to come back "attempted 0" with no
// reasons, and ⌘⌫'s plan refusals were console-only). Outcomes are
// mutually exclusive — moved / held / failed / missing / offline /
// cancelled — and requested == their sum. Every held file reaches the UI
// with its reason.
//
// Synthetic files in temp sandboxes; the Trash is a sandbox seam wherever
// a file could move.

import Foundation
import Testing
@testable import VideoScan

@Suite("Trash routine — one outcome per requested file", .serialized)
@MainActor
struct JunkOutcomeAccountingTests {

    @Test("an all-protected selection reports every file as held, with the gate's reason")
    func allProtectedIsReported() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("junkacct_protected"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let one = try MasterArchiveTestSupport.writeBlob(at: sb.archiveRoot.appendingPathComponent("test_one.mov"), bytes: 256, seed: 1)
        let two = try MasterArchiveTestSupport.writeBlob(at: sb.archiveVolume.appendingPathComponent("test_two.mov"), bytes: 256, seed: 2)
        let recs = [one, two].map { MasterArchiveTestSupport.makeRecord(path: $0.path) }
        model.records = recs
        let trash = SandboxTrash(dir: sb.root)

        let result = await model.deleteConfirmedJunk(recs, mode: .toTrash, guard: .init(
            authorize: { _ in nil }, beforeRemoval: { _ in nil }, remove: trash.operation))
        #expect(result.attempted == 2, "every requested file has an outcome: \(result.attempted)")
        #expect(result.refused.count == 2 && result.refused.map(\.record.id) == recs.map(\.id))
        #expect(result.refused.allSatisfy { $0.reason.contains("Master Archive") }, "\(result.refused.map(\.reason))")
        #expect(trash.attempts.isEmpty)
    }

    @Test("a protected file and an ordinary one: one held (named), one moved; the sum is the request")
    func mixedPreflightAndMoved() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("junkacct_mixed"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let kept = try MasterArchiveTestSupport.writeBlob(at: sb.archiveRoot.appendingPathComponent("test_kept.mov"), bytes: 256, seed: 1)
        let goes = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_goes.mov"), bytes: 256, seed: 2)
        let recs = [kept, goes].map { MasterArchiveTestSupport.makeRecord(path: $0.path) }
        model.records = recs
        let trash = SandboxTrash(dir: sb.root)

        let result = await model.deleteConfirmedJunk(recs, mode: .toTrash, guard: .init(
            authorize: { _ in nil }, beforeRemoval: { _ in nil }, remove: trash.operation))
        #expect(result.attempted == 2 && result.succeeded == 1 && result.refused.count == 1)
        #expect(result.refused.first?.record === recs[0])
        #expect(trash.attempts == [goes.path])
    }

    @Test("every bucket in one batch: moved, held, failed, missing, offline — mutually exclusive, summing to the request")
    func everyBucketSums() async throws {
        let sb = try JunkTrashSandbox("buckets"); defer { sb.cleanup() }
        let model = sb.model()
        let moved = sb.junk(try sb.write("test_moved.mov"))
        let held = sb.junk(try sb.write("test_held.mov"))
        let failing = sb.junk(try sb.write("test_failing.mov"))
        let missing = sb.junk(sb.files.appendingPathComponent("test_missing.mov"))
        let offline = VideoRecord()
        offline.fullPath = "/Volumes/test_NotMounted_\(UUID().uuidString.prefix(8))/test_off.mov"
        offline.filename = "test_off.mov"
        offline.mediaDisposition = .confirmedJunk
        let all = [moved, held, failing, missing, offline]
        model.records = all
        let trash = sb.trash.operation
        struct Locked: LocalizedError { var errorDescription: String? { "the file is locked" } }

        let result = await model.deleteConfirmedJunk(all, mode: .toTrash, guard: .init(
            authorize: { $0 === held ? "not this one" : nil },
            beforeRemoval: { _ in nil },
            remove: { url in
                if url.lastPathComponent == "test_failing.mov" { throw Locked() }
                try trash(url)
            }))
        #expect(result.attempted == 5)
        #expect(result.succeeded == 1 && result.refused.count == 1 && result.failed.count == 1)
        #expect(result.alreadyMissing == 1 && result.skippedOffline == 1)
        #expect(result.succeeded + result.refused.count + result.failed.count + result.alreadyMissing + result.skippedOffline
                == result.attempted, "outcomes are mutually exclusive and sum to the request")
    }

    // MARK: ⌘⌫ and the row menu: plan refusals reach the result

    @Test("⌘⌫: a pair member, a removed row and an offline row come back held / offline WITH reasons — not console-only")
    func catalogPlanRefusalsReachTheResult() async throws {
        let sb = try JunkTrashSandbox("cmddel"); defer { sb.cleanup() }
        let model = sb.model()
        let pair = sb.junk(try sb.write("test_pair_v.mxf"))
        pair.pairGroupID = UUID()
        let removed = sb.junk(try sb.write("test_removed.mov"))
        removed.purgedAt = Date()
        let offline = VideoRecord()
        offline.fullPath = "/Volumes/test_NotMounted_\(UUID().uuidString.prefix(8))/test_off.mov"
        offline.filename = "test_off.mov"
        model.records = [pair, removed, offline]

        let result = await model.trashSelectedRecords([pair, removed, offline])
        #expect(result.attempted == 3, "every selected row has an outcome: \(result.attempted)")
        #expect(result.skippedOffline == 1)
        #expect(result.refused.count == 2)
        #expect(result.refused.first { $0.record === pair }?.reason.contains("audio/video pair") == true, "\(result.refused.map(\.reason))")
        #expect(result.refused.first { $0.record === removed }?.reason.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: pair.fullPath) && FileManager.default.fileExists(atPath: removed.fullPath))
    }

    @Test("a run stopped mid-way: the files not reached are 'cancelled', untouched, and still counted")
    func cancelledFilesAreCounted() async throws {
        let sb = try JunkTrashSandbox("cancel"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov")), b = sb.junk(try sb.write("test_b.mov"))
        model.records = [a, b]
        let trash = sb.trash.operation
        let inFirst = OrderLog()
        let release = DispatchSemaphore(value: 0)
        let run = Task { @MainActor in
            await model.deleteConfirmedJunk([a, b], mode: .toTrash, guard: .init(
                authorize: { _ in nil }, beforeRemoval: { _ in nil },
                remove: { url in
                    inFirst.add(url.lastPathComponent)
                    if url.lastPathComponent == "test_a.mov" { release.wait() }
                    try trash(url)
                }))
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while inFirst.entries.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        run.cancel()
        release.signal()
        let result = await run.value
        #expect(result.attempted == 2 && result.succeeded == 1 && result.cancelled == 1, "\(result.items.map(\.outcome.kind))")
        #expect(FileManager.default.fileExists(atPath: b.fullPath) && b.purgedAt == nil)
    }

    // MARK: The UI's presenter: every file that stayed, with its reason

    @Test("the report lists EVERY file that did not move, in request order, each with a reason; moved files are not listed")
    func reportListsEveryHeldFile() {
        func rec(_ name: String) -> VideoRecord { let r = VideoRecord(); r.filename = name; return r }
        struct Locked: LocalizedError { var errorDescription: String? { "the file is locked" } }
        let result = VideoScanModel.JunkDeletionResult(items: [
            .init(record: rec("test_moved.mov"), outcome: .moved),
            .init(record: rec("test_held.mov"), outcome: .held("lives on FamilyArchive")),
            .init(record: rec("test_failed.mov"), outcome: .failed(Locked())),
            .init(record: rec("test_missing.mov"), outcome: .missing),
            .init(record: rec("test_offline.mov"), outcome: .offline),
            .init(record: rec("test_cancelled.mov"), outcome: .cancelled),
        ])
        let report = JunkDeletionReport(result)
        #expect(report.lines.map(\.filename) == ["test_held.mov", "test_failed.mov", "test_missing.mov",
                                                  "test_offline.mov", "test_cancelled.mov"])
        #expect(report.lines.allSatisfy { !$0.reason.isEmpty })
        #expect(report.lines[0].reason == "lives on FamilyArchive")
        #expect(report.lines[1].reason.contains("the file is locked"))
        #expect(report.summary.count == 6, "\(report.summary)")
        #expect(report.summary.first == "Moved 1 file to the Trash")
        #expect(report.linesText.components(separatedBy: "\n").count == 5)
    }

    @Test("scale: a 100k-file result reports every held file (nothing truncated) in under a second")
    func reportAtScale() {
        let records = (0..<100_000).map { i -> VideoRecord in let r = VideoRecord(); r.filename = "test_\(i).mov"; return r }
        let result = VideoScanModel.JunkDeletionResult(items: records.enumerated().map { i, r in
            .init(record: r, outcome: i.isMultiple(of: 2) ? .moved : .held("reason \(i)"))
        })
        let clock = ContinuousClock()
        let start = clock.now
        let report = JunkDeletionReport(result)
        #expect(clock.now - start < .seconds(1))
        #expect(report.lines.count == 50_000 && report.lines.last?.reason == "reason 99999")
    }

    /// Sensor: both UIs render the one presenter; the sheet's list is lazy
    /// and uncapped; nothing says "see the app log".
    @Test("sensor: Triage's result sheet and the Catalog alert both render JunkDeletionReport, uncapped")
    func bothSurfacesRenderTheReport() throws {
        let sheet = try SourceTree.appCode(named: "DeleteConfirmedJunkSheet.swift")
        #expect(sheet.contains("let report: JunkDeletionReport"))
        #expect(sheet.contains("LazyVStack") && sheet.contains("ForEach(report.lines)"))
        #expect(!sheet.contains(".prefix(") && !sheet.contains("see app log"), "no capped list")
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(table.contains("let report = JunkDeletionReport(result)"))
        #expect(table.contains("alert.accessoryView = Self.reportListView(report.linesText)"))
        let triage = try SourceTree.appCode(named: "TriageView.swift")
        #expect(triage.contains("junkSheet = .result(JunkDeletionReport(result)"))
    }

    @Test("⌘⌫ on a viewer Mac: every row held with the reason, nothing moved")
    func catalogViewerIsReported() async throws {
        let sb = try JunkTrashSandbox("cmdviewer"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        model.isReadOnly = true
        let result = await model.trashSelectedRecords([a])
        #expect(result.attempted == 1 && result.refused.count == 1)
        #expect(result.refused.first?.reason.contains("read-only viewer") == true)
        #expect(FileManager.default.fileExists(atPath: a.fullPath))
    }
}
