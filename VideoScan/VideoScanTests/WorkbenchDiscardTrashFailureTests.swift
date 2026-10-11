// WorkbenchDiscardTrashFailureTests.swift
//
// B1 of docs/reviews/night/diagnose_trash_and_volume_floor_2026_10_10.md:
// Workbench Discard did
//
//     if (try? trash(url)) != nil { trashed.append(rec) }
//     rec.purgedAt = now
//     rec.lifecycleStage = .trashed
//
// so a Trash call that THREW still stamped the record purged + Trashed —
// the file stayed on disk, labelled as gone, hidden from every live view.
// The fix: each file gets one outcome (moved | held | failed | missing |
// offline), the record is stamped only for moved / missing, every file
// gets an audit line, and the run ends with the same OUTCOME line the
// other delete verbs write (DeletionAudit).
//
// B4 of the same doc: restoreRecord / undoLastPurge cleared purgedAt but
// left lifecycleStage == .trashed, so a restored row still said Trashed.
//
// (For Rick: the `trash:` parameter is a std::function injected for tests —
// production gets FileManager.trashItem.)

import Foundation
import Testing
@testable import VideoScan

private struct TrashRefused: LocalizedError {
    var errorDescription: String? { "test_trash_refused — the volume has no Trash" }
}

@Suite("Workbench Discard — a failed Trash leaves the record alone (B1)", .serialized)
@MainActor
struct WorkbenchDiscardTrashFailureTests {

    private func scratch(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_wb_discard_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func model(_ dir: URL) -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        return m
    }

    /// A Workbench record; `create` = put a real file at its path.
    private func item(_ dir: URL, _ name: String, create: Bool = true) -> VideoRecord {
        let url = dir.appendingPathComponent(name)
        if create { FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3, 4])) }
        let r = VideoRecord()
        r.filename = name
        r.fullPath = url.path
        r.directory = dir.path
        r.sizeBytes = 4
        r.lifecycleStage = .workbench
        return r
    }

    /// The console after the dashboard's flush debounce.
    private func console(_ m: VideoScanModel) async -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return m.dashboard.consoleLines.joined(separator: "\n")
    }

    @Test func aTrashThatThrowsLeavesTheRecordUntouchedAndCountsFailed() async throws {
        let dir = try scratch("fail"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let rec = item(dir, "test_keep.mov")
        m.records = [rec]

        let n = m.discardWorkbench([rec], trash: { _ in throw TrashRefused() })

        #expect(n == 0, "a failed Trash is not a discard")
        #expect(rec.purgedAt == nil, "a failed Trash stamped purgedAt — the file is still on disk")
        #expect(rec.lifecycleStage == .workbench, "a failed Trash relabelled the row \(rec.lifecycleStage)")
        #expect(FileManager.default.fileExists(atPath: rec.fullPath))
        let log = await console(m)
        #expect(log.contains("failed \(rec.fullPath)"), "no per-file failure line:\n\(log)")
        #expect(log.contains("test_trash_refused"), "the failure line must carry the error:\n\(log)")
        #expect(log.contains("OUTCOME Discard — moved 0"), "no OUTCOME line:\n\(log)")
        #expect(log.contains("· failed 1 ·"), "the failure is not counted in the OUTCOME:\n\(log)")
    }

    @Test func oneFailureDoesNotStopTheBatchAndOnlyTheMovedFileIsStamped() async throws {
        let dir = try scratch("mixed"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let stuck = item(dir, "test_stuck.mov"), goes = item(dir, "test_goes.mov")
        m.records = [stuck, goes]
        var moved: [String] = []

        let n = m.discardWorkbench([stuck, goes]) { url in
            if url.lastPathComponent == "test_stuck.mov" { throw TrashRefused() }
            moved.append(url.lastPathComponent)
        }

        #expect(n == 1)
        #expect(moved == ["test_goes.mov"])
        #expect(stuck.purgedAt == nil && stuck.lifecycleStage == .workbench)
        #expect(goes.purgedAt != nil && goes.lifecycleStage == .trashed)
        let log = await console(m)
        #expect(log.contains("moved 1") && log.contains("· failed 1 ·"), Comment(rawValue: log))
        // Persisted as such: the failed row is still live in catalog.json.
        let reloaded = Dictionary(uniqueKeysWithValues: m.catalogStore.load().map { ($0.id, $0) })
        #expect(reloaded[stuck.id]?.purgedAt == nil)
        #expect(reloaded[goes.id]?.lifecycleStage == .trashed)
    }

    @Test func aSuccessfulTrashStillStampsTheRecordAndWritesTheReceipt() async throws {
        let dir = try scratch("ok"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let rec = item(dir, "test_ok.mov")
        m.records = [rec]
        var calls = 0

        let n = m.discardWorkbench([rec], trash: { _ in calls += 1 })

        #expect(n == 1 && calls == 1)
        #expect(rec.purgedAt != nil && rec.lifecycleStage == .trashed)
        let log = await console(m)
        #expect(log.contains("START Discard"), Comment(rawValue: log))
        #expect(log.contains("moved \(rec.fullPath)"), Comment(rawValue: log))
        #expect(log.contains("OUTCOME Discard — moved 1"), Comment(rawValue: log))
        // The receipt: one row per requested file.
        let receiptPath = try #require(log.components(separatedBy: "receipt: ").last?
            .components(separatedBy: "\n").first)
        let rows = try String(contentsOfFile: receiptPath, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 2 && rows[1].hasPrefix("moved,"), "\(rows)")
        try? FileManager.default.removeItem(atPath: receiptPath)
    }

    @Test func aFileWhoseDriveIsNotConnectedIsLeftAloneAsOffline() async throws {
        let dir = try scratch("offline"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let rec = VideoRecord()
        rec.filename = "test_away.mov"
        rec.fullPath = "/Volumes/VS-test-NoSuchDrive-\(UUID().uuidString.prefix(8))/test_away.mov"
        rec.lifecycleStage = .workbench
        m.records = [rec]
        var calls = 0

        let n = m.discardWorkbench([rec], trash: { _ in calls += 1 })

        #expect(n == 0 && calls == 0)
        #expect(rec.purgedAt == nil && rec.lifecycleStage == .workbench,
                "a file on an unplugged drive is not gone — the record must stay")
        #expect(await console(m).contains("· offline 1 ·"))
    }

    @Test func anAlreadyMissingFileOnAConnectedDriveIsPurgedWithoutATrashCall() async throws {
        let dir = try scratch("missing"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let rec = item(dir, "test_ghost.mov", create: false)
        m.records = [rec]
        var calls = 0

        let n = m.discardWorkbench([rec], trash: { _ in calls += 1 })

        #expect(n == 1 && calls == 0)
        #expect(rec.purgedAt != nil, "a vanished workbench file must not leave an un-purgeable row")
        #expect(await console(m).contains("· missing 1 ·"))
    }
}

// MARK: - B4: restore puts the record back to its live stage

@Suite("Restore — a restored row is live again, not 'Trashed' (B4)", .serialized)
@MainActor
struct RestoreResetsTrashedStageTests {

    /// A purged record in a fresh scratch dir; `onDisk` = its file is back
    /// at fullPath (Put Back in Finder happened). The caller removes `dir`.
    private func purged(_ stage: LifecycleStage, onDisk: Bool) throws -> (rec: VideoRecord, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_restore_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = VideoRecord()
        r.filename = "test_restore.mov"
        r.fullPath = dir.appendingPathComponent(r.filename).path
        if onDisk { FileManager.default.createFile(atPath: r.fullPath, contents: Data([1, 2, 3])) }
        r.purgedAt = Date()
        r.lifecycleStage = stage
        return (r, dir)
    }

    private func model(_ recs: [VideoRecord], in dir: URL) -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        m.records = recs
        return m
    }

    @Test func restoreRecordClearsTheTrashedStage() throws {
        let (rec, dir) = try purged(.trashed, onDisk: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model([rec], in: dir)
        #expect(m.restoreRecord(id: rec.id))
        #expect(rec.purgedAt == nil)
        #expect(rec.lifecycleStage == .cataloged, "a restored row still reads \(rec.lifecycleStage)")
    }

    @Test func undoLastPurgeClearsTheTrashedStage() throws {
        let (rec, dir) = try purged(.trashed, onDisk: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model([rec], in: dir)
        m.lastPurgedBatch = .init(ids: [rec.id], timestamp: rec.purgedAt ?? Date())
        #expect(m.undoLastPurge())
        #expect(rec.purgedAt == nil && rec.lifecycleStage == .cataloged)
    }

    @Test func restoreKeepsALiveStageItAlreadyHad() throws {
        let (rec, dir) = try purged(.archived, onDisk: true)   // Remove from Catalog never touches the stage
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model([rec], in: dir)
        #expect(m.restoreRecord(id: rec.id))
        #expect(rec.lifecycleStage == .archived)
    }

    /// Manager ruling (QA on 3e8e14dbd): the file is still in the Trash (or
    /// gone), so the row must not claim to be live media. It is un-purged as
    /// before, keeps its Trashed stage, and one line says what to do.
    @Test func restoringATrashedRowWhoseFileIsNotOnDiskDoesNotClaimItIsCataloged() async throws {
        let (rec, dir) = try purged(.trashed, onDisk: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model([rec], in: dir)
        #expect(m.restoreRecord(id: rec.id))
        #expect(rec.purgedAt == nil, "Restore still un-purges the row")
        #expect(rec.lifecycleStage == .trashed, "a row whose file is not on disk was relabelled \(rec.lifecycleStage)")
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce
        let log = m.dashboard.consoleLines.joined(separator: "\n")
        #expect(log.contains("test_restore.mov is still in the Trash (or gone) — Put Back in Finder, then Restore again to mark it live."),
                Comment(rawValue: log))
    }
}

// MARK: - Sensor: no delete verb stamps a purge after a swallowed Trash

@Suite("Sensor — a swallowed Trash call is never followed by a purge stamp (B1)")
struct SwallowedTrashThenPurgeSensorTests {

    /// Lines (1-based) where a `try?` trash call is followed, within
    /// `window` lines, by a purge / Trashed stamp.
    static func offendingLines(in code: String, window: Int = 6) -> [Int] {
        let lines = code.components(separatedBy: "\n")
        let swallowedTrash = #/try\?\s*[\w.]*[tT]rash\w*\(/#
        let stamp = #/purgedAt\s*=|lifecycleStage\s*=\s*\.trashed/#
        var hits: [Int] = []
        for (i, line) in lines.enumerated() where line.contains(swallowedTrash) {
            let after = lines[i..<min(lines.count, i + 1 + window)]
            if after.contains(where: { $0.contains(stamp) }) { hits.append(i + 1) }
        }
        return hits
    }

    @Test("the detector catches the B1 shape")
    func detectorCatchesTheOldDiscard() {
        let old = """
            if (try? trash(url)) != nil { trashed.append(rec) }
            rec.purgedAt = now
            rec.lifecycleStage = .trashed
            """
        #expect(Self.offendingLines(in: old) == [1])
        let cleanup = "try? FileManager.default.trashItem(at: photo, resultingItemURL: nil)\n}"
        #expect(Self.offendingLines(in: cleanup).isEmpty)
    }

    @Test("sensor: no app source stamps purgedAt / .trashed after a swallowed Trash")
    func noAppSourceStampsAfterASwallowedTrash() throws {
        #expect(SourceTree.appSources.count > 100, "read nothing")
        var found: [String] = []
        for entry in SourceTree.appSources {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            let code = SourceTree.scan(text).unsupported.isEmpty ? SourceTree.scan(text).code : text
            for line in Self.offendingLines(in: code) { found.append("\(entry.relative):\(line)") }
        }
        #expect(found.isEmpty, "a delete verb stamps the record although the Trash call's error was swallowed: \(found)")
    }

    @Test("sensor: Workbench Discard writes the deletion audit")
    func discardIsAudited() throws {
        let code = try SourceTree.appCode(named: "VideoScanModel+Workbench.swift")
        #expect(code.contains("DeletionAudit("))
        #expect(!code.contains("try? trash("))
    }
}
