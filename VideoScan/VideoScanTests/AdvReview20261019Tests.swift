// AdvReview20261019Tests.swift
//
// Adversarial review 2026-10-19 (cycle #110), docs/reviews/adversarial/2026-10-19.md.
//
//   F-snapshot  AdvRelocateSnapshotUnderSQLiteTests — Migrate's "Pre-migrate
//               snapshot" copied catalog.json, which is frozen once
//               catalog.sqlite is the authority. Now it goes through
//               `snapshotCatalog` (commit first, then seal catalog.sqlite).
//   F-bucketB   AdvRelocateBucketBPresentFileTests — Bucket B is "whatever is
//               left", not "the file is absent". A file still at its path
//               (edited in place, or unreadable for the partial MD5) was
//               marked Missing / Manually Deleted. Now the disk is asked at
//               mark time; only "nothing there" marks.
//   F-history   AdvRescanKeepsReplacedHistoryTests — a rescan purged the
//               curated `replacedAtPath` history row that sits beside its
//               successor at the same path.
//   F-applied   AdvRescanLiveAppliedCountTests — the live-wins reconcile's
//               count reaches the merge outcome (and its summary line).
//   F-summary   AdvRelocateClosingSummaryTests — rows Bucket B could not mark
//               (refused by the catalog, or still on disk) are in Migrate's
//               closing summary.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     each finding's shape, plus its control
//   SCALE     Bucket B over 2,000 rows with presence asked; a 100k rescan with
//             1,000 history rows inside its budget
//   ISOLATION temp folders / CutoverScene sandboxes only
//   SENSOR    SQLite: the pre-migrate snapshot holds a row added after the
//             switch; the history row is still in catalog.sqlite after a
//             rescan and a relaunch
//   MEDIA     N/A — byte files stand in; no media is opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private func deterministicBytes(_ count: Int, seed: Int) -> Data {
    var d = Data(count: count)
    for i in 0..<count { d[i] = UInt8((i &* seed) % 251) }
    return d
}

private func makeWorkspace(_ label: String) throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vs-adv1019-\(label)-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let dest = root.appendingPathComponent("dest", isDirectory: true)
    let catalog = root.appendingPathComponent("catalog", isDirectory: true)
    for dir in [source, dest, catalog] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    return (root, source, dest, catalog)
}

private func record(at file: URL, size: Int64, md5: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = file.lastPathComponent
    r.fullPath = file.path
    r.directory = file.deletingLastPathComponent().path
    r.sizeBytes = size
    r.partialMD5 = md5
    return r
}

// MARK: - F-snapshot

@Suite("Adv 2026-10-19 — Migrate's pre-migrate snapshot under catalog.sqlite is the catalog in use", .serialized)
@MainActor
struct AdvRelocateSnapshotUnderSQLiteTests {

    @Test("a row added after the switch is in the pre-migrate snapshot, at its source path")
    func preMigrateSnapshotIsTheCatalogInUse() async throws {
        let scene = try CutoverScene.make("adv1019_relocate_snapshot"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)

        let ws = try makeWorkspace("snap")
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let file = ws.source.appendingPathComponent("test_clip-0001.mov")
        let bytes = deterministicBytes(2_048, seed: 31)
        try bytes.write(to: file)
        let rec = record(at: file, size: Int64(bytes.count), md5: FileHasher.partialMD5(path: file.path))
        scene.model.records.append(rec)
        try #require(scene.model.saveCatalogNow(), "fixture: the new row is committed to catalog.sqlite")

        scene.model.relocateVolume(RelocateOptions(sourceVolumeRootPath: ws.source.path, destinationRoot: ws.dest,
                                                   maxConcurrency: 1, dryRun: false, skipAlreadyRelocated: true))
        let runner = try #require(scene.model.relocateRunnerTask)
        await runner.value
        let summary = try #require(scene.model.pendingRelocateSummary)
        let snap = try #require(summary.snapshotPath, "a real Migrate advertised no pre-migrate snapshot")

        #expect(snap.hasSuffix(".sqlite"), "under catalog.sqlite the safety copy is a sealed .sqlite copy, got \(snap)")
        #expect((snap as NSString).lastPathComponent.hasPrefix("catalog.pre-relocate."))
        let carriesRow: Bool
        if snap.hasSuffix(".sqlite") {
            let loaded = try await CutoverScene.load(URL(fileURLWithPath: snap))
            carriesRow = loaded.records.contains { $0.id == rec.id && $0.fullPath == file.path }
        } else {
            let text = try String(contentsOf: URL(fileURLWithPath: snap), encoding: .utf8)
                .replacingOccurrences(of: "\\/", with: "/")
            carriesRow = text.contains(rec.id.uuidString) && text.contains(file.path)
        }
        #expect(carriesRow, "the 'Pre-migrate snapshot' \((snap as NSString).lastPathComponent) is not the catalog in use — the row this Migrate moved is not in it")
    }

    /// Control under catalog.json: the snapshot is still a .json beside the
    /// catalog, and holds an edit made inside the save debounce (it is
    /// written from memory now, not copied from disk).
    @Test("catalog.json: the snapshot is JSON and holds an unsaved edit")
    func jsonAuthoritySnapshotHoldsMemory() async throws {
        let ws = try makeWorkspace("snapjson")
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let file = ws.source.appendingPathComponent("test_clip-0002.mov")
        let bytes = deterministicBytes(1_024, seed: 7)
        try bytes.write(to: file)
        let rec = record(at: file, size: Int64(bytes.count), md5: FileHasher.partialMD5(path: file.path))
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]
        _ = model.catalogStore.saveNow(records: [rec])
        rec.userNotes = "test sentinel typed inside the debounce"

        model.relocateVolume(RelocateOptions(sourceVolumeRootPath: ws.source.path, destinationRoot: ws.dest,
                                             maxConcurrency: 1, dryRun: false, skipAlreadyRelocated: true))
        let runner = try #require(model.relocateRunnerTask)
        await runner.value
        let snap = try #require(model.pendingRelocateSummary?.snapshotPath)
        #expect(snap.hasSuffix(".json"))
        let text = try String(contentsOf: URL(fileURLWithPath: snap), encoding: .utf8)
        #expect(text.contains("test sentinel typed inside the debounce"))
    }
}

// MARK: - F-bucketB

@Suite("Adv 2026-10-19 — Migrate never marks a file that is still at its path 'source not found'", .serialized)
@MainActor
struct AdvRelocateBucketBPresentFileTests {

    @Test("a file edited in place since the scan (new size) is not marked Missing / Manually Deleted")
    func aFileStillAtItsPathIsNeverMarkedNotFound() async throws {
        let ws = try makeWorkspace("bpresent")
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let file = ws.source.appendingPathComponent("test_clip-0002.mov")
        let original = deterministicBytes(4_096, seed: 13)
        try original.write(to: file)
        let rec = record(at: file, size: Int64(original.count), md5: FileHasher.partialMD5(path: file.path))
        // Edited in place after the scan: same path, new bytes, new size.
        try (original + Data(repeating: 9, count: 1_000)).write(to: file)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]
        _ = model.catalogStore.saveNow(records: [rec])

        model.relocateVolume(RelocateOptions(sourceVolumeRootPath: ws.source.path, destinationRoot: ws.dest,
                                             maxConcurrency: 1, dryRun: false, skipAlreadyRelocated: true))
        let runner = try #require(model.relocateRunnerTask)
        await runner.value

        #expect(FileManager.default.fileExists(atPath: file.path), "fixture: the file never left its path")
        #expect(rec.removal?.state != .missing, "the row reads Missing while its file is at its path")
        #expect(rec.archiveStage != .manuallyDeleted, "Retire's 'disposed' label on a file that is still there")
        #expect(!rec.notes.contains("source file not found"))
        #expect(model.dashboard.relocateManuallyDeleted == 0, "the summary says 'Manually deleted: 1'")
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.manuallyDeletedCount == 0)
        #expect(summary.stillThereCount == 1, "the closing summary does not say the row was left because its file is there")
        let console = await consoleText(model)
        #expect(console.contains("still at their path"), Comment(rawValue: console))
    }

    @Test("presence decides: nothing there → marked; a file there → not marked; could not look → not marked")
    func presenceDecidesEachRow() async throws {
        let model = VideoScanModel()
        func row(_ name: String) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = "/Volumes/TestDrive/\(name)"
            r.directory = "/Volumes/TestDrive"
            return r
        }
        let gone = row("test_gone.mov"), there = row("test_there.mov"), unknown = row("test_unknown.mov")
        model.records = [gone, there, unknown]
        let answers: [String: JourneyPresence] = [
            gone.fullPath: .missing,
            there.fullPath: .regularFile,
            unknown.fullPath: .unknown(reason: "Input/output error")
        ]
        model.markBucketBSourcesNotFound([gone, there, unknown], presence: { answers[$0] ?? .missing })

        #expect(gone.removal?.state == .missing)
        #expect(gone.archiveStage == .manuallyDeleted)
        for r in [there, unknown] {
            #expect(r.removal == nil, Comment(rawValue: r.filename))
            #expect(r.archiveStage != .manuallyDeleted, Comment(rawValue: r.filename))
            #expect(!r.notes.contains("source file not found"), Comment(rawValue: r.filename))
        }
        #expect(model.dashboard.relocateManuallyDeleted == 1)
        #expect(model.dashboard.relocateBucketBStillThere == 2)
        #expect(model.dashboard.relocateCompleted == 3, "the progress bar still reaches the end")
        let console = await consoleText(model)
        #expect(console.components(separatedBy: "still at their path").count - 1 == 1, Comment(rawValue: console))
        #expect(console.contains("1 could not be checked"), Comment(rawValue: console))
    }

    @Test("SCALE: 2,000 Bucket B rows still on disk → none marked, one line, inside the budget")
    func manyPresentRowsOneLine() async throws {
        let model = VideoScanModel()
        let n = 2_000
        var rows: [VideoRecord] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            let r = VideoRecord()
            r.filename = "test_\(i).mov"
            r.fullPath = "/Volumes/TestDrive/test_\(i).mov"
            rows.append(r)
        }
        model.records = rows
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            model.markBucketBSourcesNotFound(rows, presence: { _ in .regularFile })
        }
        #expect(model.dashboard.relocateManuallyDeleted == 0)
        #expect(model.dashboard.relocateBucketBStillThere == n)
        #expect(model.dashboard.relocateCompleted == n)
        #expect(rows.allSatisfy { $0.removal == nil })
        let console = await consoleText(model)
        #expect(console.components(separatedBy: "still at their path").count - 1 == 1)
        #expect(elapsed < .seconds(10), "Bucket B of \(n) present rows took \(elapsed)")
    }
}

// MARK: - F-summary

@Suite("Adv 2026-10-19 — Migrate's closing summary names the Bucket B rows it did not mark", .serialized)
@MainActor
struct AdvRelocateClosingSummaryTests {

    @Test("held catalog: the closing block and relocate.log line say how many rows were NOT marked")
    func refusedRowsAreInTheClosingSummary() async throws {
        let scene = try CutoverScene.make("adv1019_relocate_summary"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let rows = [try scene.record(.healthy), try scene.record(.curatedConflictA)]
        #expect(scene.model.saveCatalogNow())
        await scene.hold()
        defer { scene.release() }

        scene.model.markBucketBSourcesNotFound(rows, presence: { _ in .missing })
        #expect(scene.model.dashboard.relocateManuallyDeleted == 0)
        #expect(scene.model.dashboard.relocateBucketBNotMarked == 2)
        let lines = scene.model.relocateClosingSummaryLines(elapsed: 1, savedMB: 0, mb: 0, mbps: 0)
        #expect(lines.console.contains("Not marked:       2"), Comment(rawValue: lines.console))
        #expect(lines.log.contains("notMarked=2"), Comment(rawValue: lines.log))
        #expect(lines.log.contains("stillThere=0"), Comment(rawValue: lines.log))
    }

    @Test("free catalog, nothing refused: the closing block has no 'Not marked' row")
    func nothingRefusedNoRow() async throws {
        let model = VideoScanModel()
        let lines = model.relocateClosingSummaryLines(elapsed: 1, savedMB: 0, mb: 0, mbps: 0)
        #expect(!lines.console.contains("Not marked"))
        #expect(!lines.console.contains("Still at path"))
        #expect(lines.log.contains("notMarked=0 stillThere=0"))
    }
}

// MARK: - F-history

@Suite("Adv 2026-10-19 — a rescan keeps the replacedAtPath history row", .serialized)
@MainActor
struct AdvRescanKeepsReplacedHistoryTests {

    private static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_adv1019_history_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func row(_ path: String, size: Int64) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = size
        return r
    }

    /// What placeRecord's `retire` leaves (CatalogCutoverB24Tests): the
    /// earlier, curated row kept as history at the path, its successor beside it.
    private static func historyAndSuccessor(_ path: String) -> (VideoRecord, VideoRecord) {
        let history = row(path, size: 1_000)
        history.userNotes = "synthetic note on the earlier take"
        history.starRating = 4
        history.userDate = "2001-01"
        history.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_000_000), reason: .replacedAtPath)
        let successor = row(path, size: 2_000)
        successor.notes = "Balance Audio 2026-10-18T10:00:00Z: synthetic stamp"
        return (history, successor)
    }

    @Test("complete rescan: the curated history row and its id stay; the successor is refreshed")
    func rescanKeepsTheCuratedReplacedAtPathRow() async throws {
        let root = try Self.makeRoot("complete"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_clip_balanced.mov").path
        let (history, successor) = Self.historyAndSuccessor(path)
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        model.records = [history, successor]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = Self.row(path, size: 2_000)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: true)

        #expect(model.records.contains {
                    $0.id == history.id && $0.userNotes == "synthetic note on the earlier take"
                        && $0.starRating == 4 && $0.userDate == "2001-01"
                        && $0.removal?.reason == .replacedAtPath
                },
                "the replacedAtPath row's curation left the catalog with the rescan")
        #expect(!model.records.contains { $0 === successor }, "the successor is still replaced by the fresh record")
        #expect(model.records.contains { $0 === fresh })
        #expect(fresh.removal == nil, "the fresh record never takes the history row's marker")
        #expect(model.records.filter { $0.fullPath == path }.count == 2)
    }

    @Test("partial rescan: the history row stays too")
    func partialRescanKeepsHistory() async throws {
        let root = try Self.makeRoot("partial"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_clip_balanced.mov").path
        let (history, successor) = Self.historyAndSuccessor(path)
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        model.records = [successor, history]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = Self.row(path, size: 2_000)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: false)
        #expect(model.records.contains { $0 === history })
        #expect(!model.records.contains { $0 === successor })
    }

    @Test("SENSOR: catalog.sqlite still holds the history row after the rescan and a relaunch")
    func historyRowSurvivesInCatalogSQLite() async throws {
        let scene = try CutoverScene.make("adv1019_history"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let successor = try scene.record(.healthy)
        let path = successor.fullPath
        let root = (path as NSString).deletingLastPathComponent
        let history = try scene.freshCopy(of: .healthy, path: path)
        RescanPreservedFields(from: VideoRecord()).apply(to: history)
        history.userNotes = "synthetic note on the earlier take"
        history.starRating = 4
        history.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_000_000), reason: .replacedAtPath)
        model.records.append(history)
        #expect(model.saveCatalogNow())

        let target = CatalogScanTarget(searchPath: root)
        model.snapshotPreservedFieldsForRescan(of: target)
        let probed = try scene.freshCopy(of: .healthy, path: path)
        RescanPreservedFields(from: VideoRecord()).apply(to: probed)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [probed])
        _ = await model.commitScanResults(root: root, volName: "Fixture",
                                          targetRecords: [probed], scanWasComplete: false)
        #expect(model.saveCatalogNow())

        try await scene.relaunch()
        let kept = try #require(model.records.first { $0.id == history.id }, "the history row was purged from catalog.sqlite")
        #expect(kept.userNotes == "synthetic note on the earlier take")
        #expect(kept.starRating == 4)
        #expect(kept.removal?.reason == .replacedAtPath)
    }

    @Test("scale: 100k rows with 1,000 history pairs merge within budget", .timeLimit(.minutes(1)))
    func scale_100kWithHistoryWithinBudget() async {
        let model = VideoScanModel()
        let root = "/Volumes/AdvScale"
        let target = CatalogScanTarget(searchPath: root)
        var old: [VideoRecord] = []
        old.reserveCapacity(101_000)
        var histories: [VideoRecord] = []
        for i in 0..<100_000 {
            let r = Self.row("\(root)/\(i % 100)/clip\(i).mov", size: Int64(i))
            old.append(r)
            if i % 100 == 0 {
                let h = Self.row(r.fullPath, size: Int64(i) + 1)
                h.userNotes = "history \(i)"
                h.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_000_000), reason: .replacedAtPath)
                histories.append(h)
            }
        }
        model.records = old + histories
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = old.map { Self.row($0.fullPath, size: $0.sizeBytes) }
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await model.commitScanResults(root: root, volName: "AdvScale",
                                              targetRecords: fresh, scanWasComplete: false)
        }
        #expect(model.records.count == 101_000)
        let ids = Set(model.records.map(\.id))
        #expect(histories.allSatisfy { ids.contains($0.id) })
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(3)),
                "100k partial merge with history rows took \(elapsed) — budget 3s")
    }
}

// MARK: - F-applied

@Suite("Adv 2026-10-19 — the merge says how many records took live values", .serialized)
@MainActor
struct AdvRescanLiveAppliedCountTests {

    @Test("an edit during the scan is counted; a plain record is not")
    func liveAppliedCountReachesTheOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_adv1019_applied_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func row(_ name: String) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = root.appendingPathComponent(name).path
            r.directory = root.path
            r.sizeBytes = 10
            return r
        }
        let edited = row("test_edited.mov"), plain = row("test_plain.mov")
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        model.records = [edited, plain]
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        model.setUserNotes("test note typed during the scan", for: edited)
        let fresh = [row("test_edited.mov"), row("test_plain.mov")]
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)

        let complete = await model.commitScanResults(root: root.path, volName: "Adv",
                                                     targetRecords: fresh, scanWasComplete: true)
        #expect(complete.liveValuesApplied == 1)
        #expect(fresh[0].userNotes == "test note typed during the scan")
    }
}
