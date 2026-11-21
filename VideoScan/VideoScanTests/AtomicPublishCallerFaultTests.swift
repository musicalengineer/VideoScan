// AtomicPublishCallerFaultTests.swift
//
// What the STORES do when their publish fails half-way (survey 2026-11-20:
// "AtomicFilePublish: fsync fails, rename fails after the temp is written" —
// untestable until `AtomicFilePublish.$hooks`). One suite per caller, chosen
// for what the file is to truth or recovery:
//
//   1. DeleteDuplicatesPlanWriter   plan.json — what makes a resume honest
//   2. ArchiveIndexRename           the App Support ledger rewritten by a rename
//   3. IntegrityReportStore         integrity-latest.json — what Catalog Status reads
//   4. CatalogAuditRunMarker        catalog-audit.json — File Presence + the importer
//   5. ArchiveAuditStore            archive-audit.json — Rick's keep-both / tags
//   6. EventsStats                  events_latest.json — the Events page's counts (metrics)
//   7. FullHashBackfillResumeMarker fullhash-backfill.json — the Resume offer (parked, in suite 5)
// (The catalog's own commit door, catalog.highwater, is in VideoScanCore:
// CatalogHighWaterPublishFaultTests.)
//
// The contract asked of each: the failure is SURFACED (thrown, returned or
// said in the log — never swallowed), the previous file stands byte for
// byte, no temp is left, and the write is not recorded or announced as done.
//
// Every fault is task-local, so the suites run in parallel; each test counts
// the fault's hits to prove it was taken. The two tests that read the app
// log bind their own capture for their own task tree (`withAppLog`), so they
// are parallel-safe too.
//
// Five dimensions: logic (here) · scale n/a (one small file per publish) ·
// media n/a · isolation (each test owns a scratch folder and its own hooks) ·
// sensor (the primitive's, AtomicFilePublishFaultTests in VideoScanCore).

import Darwin
import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

/// A lock-protected counter a `@Sendable` hook can bump.
/// (C++: a `std::atomic<int>` shared by reference.)
private final class FaultHits: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var wasHit: Bool { lock.lock(); defer { lock.unlock() }; return n > 0 }
}

private func scratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_publishfault_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Every publish temp anywhere under `dir`.
private func temps(under dir: URL) -> [String] {
    (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
        .filter { AtomicFilePublish.isTemporaryPublishArtifact(($0 as NSString).lastPathComponent) }
}

/// The live hooks with rename failing for ONE destination only.
private func renameFailing(onto path: String, errno code: Int32, hits: FaultHits) -> AtomicFilePublish.Hooks {
    var hooks = AtomicFilePublish.Hooks.live
    let live = hooks.renameSyscall
    hooks.renameSyscall = { from, to in
        guard to == path else { return live(from, to) }
        hits.hit()
        return code
    }
    return hooks
}

// MARK: - 1. Delete Duplicates — plan.json

@Suite("Publish fault — Delete Duplicates plan.json")
struct DeleteDuplicatesPlanPublishFaultTests {

    private func plan() -> DeleteDuplicatesPlan {
        let e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/SanDisk/a.mov", filename: "a.mov", sizeBytes: 1_000,
                                           keeperID: UUID(), keeperPath: "/Volumes/LaCie/a.mov", keeperFilename: "a.mov",
                                           keeperStamp: nil)
        return DeleteDuplicatesPlan(volumePath: "/Volumes/SanDisk", catalogLocation: "/tmp/cat/catalog.json", crossVolumeMode: false,
                                    skippedBeforePlan: 0, summaryLine: "1 same-drive extra", entries: [e])
    }

    @Test("a failed save throws, the last saved plan stands, the generation is not recorded as written, and the retry lands",
          arguments: [(AtomicFilePublish.Hooks.Step.write, ENOSPC), (.fullFsync, EIO), (.rename, EACCES)])
    func aFailedSaveIsNotRecordedAsWritten(step: AtomicFilePublish.Hooks.Step, code: Int32) async throws {
        let root = try scratch("ddplan"); defer { try? FileManager.default.removeItem(at: root) }
        var p = plan()
        let writer = DeleteDuplicatesPlanWriter()
        p.log = ["generation 1"]
        #expect(try await writer.write(p, root: root, generation: 1))
        let url = DeleteDuplicatesPlanStore.planURL(for: p.id, root: root)
        let before = try Data(contentsOf: url)
        let hits = FaultHits()

        p.log = ["generation 2 — quarantined a.mov"]
        let attempt = p
        await #expect(throws: AtomicFilePublish.Failure.self) {
            try await AtomicFilePublish.$hooks.withValue(.failing(step, errno: code, onHit: { hits.hit() })) {
                try await writer.write(attempt, root: root, generation: 2)
            }
        }

        #expect(hits.count >= 1, "the fault was never reached")
        #expect(try Data(contentsOf: url) == before, "the last saved plan must stand byte for byte")
        #expect(temps(under: root).isEmpty)
        #expect(await writer.lastGeneration(for: p.id) == 1, "a save that failed must not be remembered as written")
        // Not dropped as stale: the same generation is written once the disk answers.
        #expect(try await writer.write(attempt, root: root, generation: 2))
        #expect(try DeleteDuplicatesPlanStore.load(url: url).log == ["generation 2 — quarantined a.mov"])
    }
}

// MARK: - 2. Archive rename — the App Support ledger

@Suite("Publish fault — the ledger rewrite of an archive rename")
struct LedgerRewritePublishFaultTests {

    private static func path(_ i: Int) -> String { "/Volumes/A/f\(i).mov" }
    private static let line = #"{"fullPath":"/Volumes/A/f0.mov","filename":"f0.mov"}"# + "\n"
    private static let replacements = ArchiveIndexRename.Replacements(values: [path(0): path(1)],
                                                                      oldFilename: "f0.mov", newFilename: "f1.mov")

    private func fixture() throws -> (dir: URL, ledger: URL) {
        let dir = try scratch("ledger")
        let ledger = dir.appendingPathComponent("media-ledger.jsonl")
        try Data(Self.line.utf8).write(to: ledger)
        return (dir, ledger)
    }

    /// Backup folders that still hold a copy of the ledger.
    private func backupsHoldingALedger(_ dir: URL) -> [String] {
        let backups = dir.appendingPathComponent(ArchiveIndexRename.backupFolder)
        return (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.filter {
            FileManager.default.fileExists(atPath: backups.appendingPathComponent($0).appendingPathComponent("media-ledger.jsonl").path)
        } ?? []
    }

    @Test("the ledger's own publish fails: it throws, the old ledger stands, and the backup taken for it is abandoned")
    func aFailedLedgerPublishKeepsTheOldLedger() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let hits = FaultHits()

        let thrown = #expect(throws: AtomicFilePublish.Failure.self) {
            try AtomicFilePublish.$hooks.withValue(renameFailing(onto: f.ledger.path, errno: EIO, hits: hits)) {
                _ = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: Self.replacements)
            }
        }

        #expect(hits.count == 1, "the fault was never reached")
        #expect(thrown?.operation == "rename")
        #expect(try String(contentsOf: f.ledger, encoding: .utf8) == Self.line, "the old ledger must stand")
        #expect(temps(under: f.dir).isEmpty)
        #expect(backupsHoldingALedger(f.dir).isEmpty, "a backup that protects nothing must not be left to count toward retention")
    }

    @Test("the BACKUP's publish fails: it throws and the ledger is not touched without a backup")
    func aFailedBackupPublishLeavesTheLedgerAlone() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let hits = FaultHits()

        #expect(throws: (any Error).self) {
            // F_FULLFSYNC of the first durable publish = the backup copy.
            try AtomicFilePublish.$hooks.withValue(.failing(.fullFsync, errno: EIO, onHit: { hits.hit() })) {
                _ = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: Self.replacements)
            }
        }

        #expect(hits.count == 1, "the run must stop at the first failed publish")
        #expect(try String(contentsOf: f.ledger, encoding: .utf8) == Self.line)
        #expect(temps(under: f.dir).isEmpty)
        #expect(backupsHoldingALedger(f.dir).isEmpty)
    }

    @Test("with the fault gone the same rename lands")
    func theSameRenameLandsOnceTheDiskAnswers() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(throws: (any Error).self) {
            try AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: ENOSPC)) {
                _ = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: Self.replacements)
            }
        }
        #expect(try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: Self.replacements) == 1)
        #expect(try String(contentsOf: f.ledger, encoding: .utf8).contains("/Volumes/A/f1.mov"))
        #expect(backupsHoldingALedger(f.dir).count == 1)
    }
}

// MARK: - 3. Verify Catalog — integrity-latest.json

@Suite("Publish fault — the integrity report beside the catalog")
struct IntegrityReportPublishFaultTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func report() -> IntegrityReport {
        IntegrityReport(runID: UUID(), startedAt: now.addingTimeInterval(-5), verifiedAt: now,
                        outcome: .completed, catalogFile: "/x/catalog.json", catalogGeneration: 41,
                        rowsTotal: 10, rowsLive: 9, elapsedSeconds: 5,
                        tiers: [IntegrityTier(tier: 0, name: "File presence", verifiedAt: now, result: .ok, checked: 9, passed: 9,
                                              summary: "9 rows present at their path")],
                        findings: [], findingsTotal: 0)
    }

    @Test("the latest fails after the dated copy landed: it throws, and Catalog Status still reads the PREVIOUS report")
    func aFailedLatestKeepsThePreviousReport() throws {
        let dir = try scratch("integrity"); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        let first = report()
        try IntegrityReportStore.write(first, besideCatalogAt: catalog, now: now)
        let latest = IntegrityReportStore.latestURL(besideCatalogAt: catalog)
        let before = try Data(contentsOf: latest)
        let hits = FaultHits()

        // Only the latest is published `.fullFsync`, so this fault is its alone.
        let thrown = #expect(throws: AtomicFilePublish.Failure.self) {
            try AtomicFilePublish.$hooks.withValue(.failing(.fullFsync, errno: EIO, onHit: { hits.hit() })) {
                _ = try IntegrityReportStore.write(report(), besideCatalogAt: catalog, now: now)
            }
        }

        #expect(hits.count == 1, "the fault was never reached")
        #expect(thrown?.operation == "F_FULLFSYNC")
        #expect(try Data(contentsOf: latest) == before, "the previous latest must stand byte for byte")
        #expect(IntegrityReportStore.read(besideCatalogAt: catalog).report?.runID == first.runID)
        #expect(temps(under: dir).isEmpty)
    }

    @Test("the first publish fails with nothing there before: it throws and no report appears",
          arguments: [(AtomicFilePublish.Hooks.Step.writeFast, ENOSPC), (.rename, EXDEV)])
    func aFailedFirstReportLeavesNothing(step: AtomicFilePublish.Hooks.Step, code: Int32) throws {
        let dir = try scratch("integrity0"); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        let hits = FaultHits()

        #expect(throws: (any Error).self) {
            try AtomicFilePublish.$hooks.withValue(.failing(step, errno: code, onHit: { hits.hit() })) {
                _ = try IntegrityReportStore.write(report(), besideCatalogAt: catalog, now: now)
            }
        }

        #expect(hits.count == 1, "the dated copy failed, so the latest must never be attempted")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

// MARK: - 4. Audit catalog — catalog-audit.json

@Suite("Publish fault — the catalog audit's run marker")
@MainActor
struct CatalogAuditMarkerPublishFaultTests {

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private func startedMarker(in dir: URL, lines: Lines) throws -> (CatalogAuditRunMarker, URL) {
        let marker = CatalogAuditRunMarker()
        marker.log = { lines.add($0) }
        marker.attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        marker.noteStarted()
        return (marker, try #require(marker.fileURL))
    }

    private var totals: CatalogAuditTotals {
        var t = CatalogAuditTotals()
        t.planned = 3
        t.add(.present, rows: 3)
        return t
    }

    // RED before the fix (the publish was `try?`): no line was written, so
    // a completed run left a marker on disk that says "running" — the next
    // launch said the run "did not finish (quit or crash)" and Catalog
    // Status kept the old date — and nothing anywhere said why.
    @Test("a finish that cannot be published is SAID: the marker on disk still says running, and the log says the file could not be written")
    func aFailedFinishIsSaid() throws {
        let dir = try scratch("auditmarker"); defer { try? FileManager.default.removeItem(at: dir) }
        let lines = Lines()
        let (marker, url) = try startedMarker(in: dir, lines: lines)
        let before = try Data(contentsOf: url)
        let hits = FaultHits()

        AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: ENOSPC, onHit: { hits.hit() })) {
            marker.noteFinished(.completed, totals: totals, marked: 0, partial: false, catalogGeneration: 7)
        }

        #expect(hits.count == 1, "the fault was never reached")
        #expect(try Data(contentsOf: url) == before, "the marker on disk is the one from the start of the run")
        #expect(CatalogFreshnessFactsReader.auditRecord(in: dir)?.outcome == .running)
        #expect(temps(under: dir).isEmpty)
        let said = lines.lines.filter { $0.contains(CatalogAuditRunMarker.fileName) && $0.contains("could not be written") }
        #expect(said.count == 1, "the failure must reach the log; got \(lines.lines)")
        #expect(said.first?.contains("No space left on device") == true, "the line carries the real reason")
    }

    @Test("a run on a full disk says it once, not at every checkpoint — and again after a publish has landed in between")
    func theFailureIsSaidOncePerOutage() throws {
        let dir = try scratch("auditmarker2"); defer { try? FileManager.default.removeItem(at: dir) }
        let lines = Lines()
        let (marker, url) = try startedMarker(in: dir, lines: lines)

        AtomicFilePublish.$hooks.withValue(.failing(.writeFast, errno: ENOSPC)) {
            marker.noteSaved(totals: totals, marked: 0)
            marker.noteSaved(totals: totals, marked: 0)
            marker.noteSaved(totals: totals, marked: 0)
        }
        #expect(lines.lines.count == 1)

        marker.noteSaved(totals: totals, marked: 0)                       // the disk answers again
        #expect(CatalogFreshnessFactsReader.auditRecord(in: dir)?.counts["planned"] == 3)
        AtomicFilePublish.$hooks.withValue(.failing(.writeFast, errno: EIO)) {
            marker.noteFinished(.completed, totals: totals, marked: 0, partial: false, catalogGeneration: 7)
        }
        #expect(lines.lines.count == 2)
        #expect(temps(under: dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("with nothing failing the marker says nothing and the finish is on disk")
    func aHealthyRunSaysNothing() throws {
        let dir = try scratch("auditmarker3"); defer { try? FileManager.default.removeItem(at: dir) }
        let lines = Lines()
        let (marker, _) = try startedMarker(in: dir, lines: lines)
        marker.noteSaved(totals: totals, marked: 0)
        marker.noteFinished(.completed, totals: totals, marked: 0, partial: false, catalogGeneration: 7)
        #expect(lines.lines.isEmpty)
        #expect(CatalogFreshnessFactsReader.auditRecord(in: dir)?.outcome == .completed)
    }
}

// MARK: - 5. Archive audit — archive-audit.json

@Suite("Publish fault — the archive audit's decisions and tags")
@MainActor
struct ArchiveAuditPublishFaultTests {

    @Test("the store: a failed save returns false, the previous file stands, and a reload sees only what was saved",
          arguments: [(AtomicFilePublish.Hooks.Step.write, ENOSPC), (.fullFsync, EIO), (.rename, EACCES)])
    func aFailedSaveReturnsFalseAndKeepsTheFile(step: AtomicFilePublish.Hooks.Step, code: Int32) async throws {
        let dir = try scratch("archaudit"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID(), tagged = UUID()
        let store = ArchiveAuditStore(directory: dir)
        #expect(store.keepBoth(kind: .sameFootage, ids: [a, b], titles: ["A", "B"]))
        #expect(await store.save())
        let before = try Data(contentsOf: store.fileURL)
        let hits = FaultHits()

        store.setTag(itemID: tagged, occasion: .christmas, title: "clip0042")
        let saved = await AtomicFilePublish.$hooks.withValue(.failing(step, errno: code, onHit: { hits.hit() })) {
            await store.save()
        }

        #expect(hits.count >= 1, "the fault was never reached")
        #expect(saved == false, "a save that failed must not report success")
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(temps(under: dir).isEmpty)
        let reloaded = ArchiveAuditStore(directory: dir)
        await reloaded.loadIfNeeded()
        #expect(reloaded.decisionCount == 1)
        #expect(reloaded.tag(for: tagged) == nil)
    }

    // Was PARKED RED; fixed 2026-11-21 (Rick: "we must fail but fail and
    // record the error clearly and log it clearly"). `persistArchiveAudit`
    // wrote the action to the app log as done ("Audit: tagged …") BEFORE the
    // save, then dropped the save's Bool: when the publish failed the card
    // kept its tag for the session, the app log held only the success line,
    // and the next launch showed the card untagged with nothing to say why.
    // The line is now written from the save's RESULT.
    @Test("the model: a tag whose save failed is never announced as saved — the app log says NOT SAVED, names the action and what happens at the next launch")
    func aFailedTagSaveIsSaidInTheAppLog() async throws {
        let dir = try scratch("archaudit_model"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.archiveAuditStore = ArchiveAuditStore(directory: dir)
        let sink = InMemoryLogSink()
        let hits = FaultHits()
        let item = UUID()

        // The app log is captured for this task tree only, and the model
        // saves from an unstructured `Task {}`, which inherits both the
        // capture and the fault; wait for the fault, then for the line.
        await withAppLog(sink) {
            await AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: ENOSPC, onHit: { hits.hit() })) {
                model.archiveAuditTag(itemID: item, occasion: .christmas, title: "clip0042")
                for _ in 0..<400 where !hits.wasHit { try? await Task.sleep(for: .milliseconds(5)) }
                for _ in 0..<400 where sink.lines.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }

        #expect(hits.count == 1, "the fault was never reached")
        #expect(!FileManager.default.fileExists(atPath: model.archiveAuditStore.fileURL.path), "nothing was saved")
        let audit = sink.lines.filter { $0.localizedCaseInsensitiveContains("audit") }
        #expect(audit.count == 1, "one line for one action: \(sink.lines)")
        let line = audit.first ?? ""
        #expect(line.contains("NOT SAVED") && line.contains("could not be written"), "the app log must say the tag was not saved: \(sink.lines)")
        #expect(line.contains("tagged “clip0042”"), "the line names the action: \(line)")
        #expect(line.contains("next launch"), "the line says the tag will be gone at the next launch: \(line)")
        #expect(!sink.lines.contains { $0.hasPrefix("Audit: tagged") }, "a tag that was not saved was announced as done: \(sink.lines)")
    }

    @Test("the model: a tag whose save landed is announced once, after the save, in the same words as before")
    func aSavedTagIsAnnouncedAfterTheSave() async throws {
        let dir = try scratch("archaudit_model_ok"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.archiveAuditStore = ArchiveAuditStore(directory: dir)
        let sink = InMemoryLogSink()
        let item = UUID()
        await withAppLog(sink) {
            model.archiveAuditTag(itemID: item, occasion: .christmas, title: "clip0042")
            for _ in 0..<400 where sink.lines.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(sink.lines.filter { $0.localizedCaseInsensitiveContains("audit") } == ["Audit: tagged “clip0042” as \(ArchiveOccasion.christmas.word)"],
                "\(sink.lines)")
        // The line was written from the result: the file is on disk and a reload sees the tag.
        let reloaded = ArchiveAuditStore(directory: dir)
        await reloaded.loadIfNeeded()
        #expect(reloaded.tag(for: item) != nil)
    }

    // Was PARKED RED; fixed 2026-11-21. `FullHashBackfillResumeMarker.persist`
    // was `try? AtomicFilePublish.write(…)` — the twin of the audit marker
    // fixed in suite 4. In this suite because it too reads the app log.
    //
    // Reproduction: a run starts (marker on disk: unfinished), finishes, and
    // the finish cannot be published. In this session the menu says "Fill In
    // Full Hashes…" (nothing to resume). On disk the marker still says
    // unfinished, so the NEXT launch offers "Resume…" — it cannot know
    // better: the file is all it has. What changed: the failed write is SAID
    // (once per outage), and the launch line no longer CLAIMS the run "did
    // not finish"; it says no finish is on record and that Resume will find
    // out. (Resume itself is harmless: saved hashes are skipped, and a run
    // with nothing left says so and stamps the marker finished.)
    @Test("Fill In Full Hashes: a finish that cannot be published is said in the app log, and the next launch's offer does not claim the run did not finish")
    func aFailedBackfillFinishLeavesAFalseResumeOffer() throws {
        let dir = try scratch("fullhash_marker"); defer { try? FileManager.default.removeItem(at: dir) }
        let catalogFile = dir.appendingPathComponent("catalog.json").path
        let sink = InMemoryLogSink()
        let marker = FullHashBackfillResumeMarker()
        marker.attach(catalogFile: catalogFile)
        marker.noteStarted()
        let url = try #require(marker.fileURL)
        let before = try Data(contentsOf: url)
        let hits = FaultHits()

        withAppLog(sink) {
            AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: ENOSPC, onHit: { hits.hit() })) {
                marker.noteSaved(hashedSoFar: 4)
                marker.noteSaved(hashedSoFar: 8)
                marker.noteFinished(hashed: 12)
            }
        }

        #expect(hits.count == 3, "the fault was never reached")
        #expect(try Data(contentsOf: url) == before, "the marker on disk is the one from the start of the run")
        #expect(temps(under: dir).isEmpty)
        #expect(marker.unfinished == nil && marker.menuTitle == "Fill In Full Hashes…", "this session: nothing to resume")
        // Said: once for the outage, and again that the FINISH is what was lost.
        let said = sink.lines.filter { $0.contains(FullHashBackfillResumeMarker.fileName) && $0.localizedCaseInsensitiveContains("could not") }
        #expect(said.count == 2, "once for the outage, once for the lost finish — not at every checkpoint: \(sink.lines)")
        #expect(said.last?.contains("could not record that the run finished") == true, "\(said)")
        #expect(said.last?.contains("12") == true, "the line carries what the run did: \(said)")
        // The next launch reads the stale marker: it offers Resume, and says only what the file shows.
        let relaunch = FullHashBackfillResumeMarker()
        let offered = try #require(relaunch.attach(catalogFile: catalogFile), "the next launch reads the stale marker")
        #expect(relaunch.menuTitle == "Resume Filling In Full Hashes…")
        let launch = FullHashBackfillResumeMarker.launchLine(offered)
        #expect(!launch.contains("did not finish"), "the launch line claims an unfinished run for a run that finished: \(launch)")
        #expect(launch.contains("has no finish on record (0 hashes saved)"), "\(launch)")
        #expect(launch.contains("or its finish could not be written"), "\(launch)")
    }

    @Test("Fill In Full Hashes: a healthy run says nothing; after an outage ends, the next failure is said again")
    func theBackfillMarkerSaysAFailureOncePerOutage() throws {
        let dir = try scratch("fullhash_marker2"); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = InMemoryLogSink()
        let marker = FullHashBackfillResumeMarker()
        marker.attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        withAppLog(sink) {
            marker.noteStarted()
            marker.noteSaved(hashedSoFar: 1)
            #expect(sink.lines.isEmpty, "\(sink.lines)")
            AtomicFilePublish.$hooks.withValue(.failing(.writeFast, errno: EIO)) {
                marker.noteSaved(hashedSoFar: 2)
                marker.noteSaved(hashedSoFar: 3)
            }
            #expect(sink.lines.count == 1, "\(sink.lines)")
            marker.noteSaved(hashedSoFar: 4)            // the disk answers again
            AtomicFilePublish.$hooks.withValue(.failing(.writeFast, errno: EIO)) { marker.noteSaved(hashedSoFar: 5) }
            #expect(sink.lines.count == 2, "\(sink.lines)")
            marker.noteFinished(hashed: 6)
            #expect(sink.lines.count == 2, "a finish that landed says nothing: \(sink.lines)")
        }
        let relaunch = FullHashBackfillResumeMarker()
        #expect(relaunch.attach(catalogFile: dir.appendingPathComponent("catalog.json").path) == nil, "the finish is on disk")
    }
}

// MARK: - 6. Events — events_latest.json

@Suite("Publish fault — the Events page's counts file")
@MainActor
struct EventsStatsPublishFaultTests {

    private typealias F = EventsFixture

    @Test("the writer: a failed publish returns false and the previous counts file stands")
    func aFailedWriteReturnsFalse() async throws {
        let dir = try scratch("eventsstats"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(EventsDecisionStore.statsFilename)
        let stats = EventsStats(plan: .empty, decisions: .empty, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(await EventsStats.write(stats, to: url))
        let before = try Data(contentsOf: url)
        let hits = FaultHits()

        let later = EventsStats(plan: .empty, decisions: .empty, now: Date(timeIntervalSince1970: 1_790_009_000))
        let written = await AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: EIO, onHit: { hits.hit() })) {
            await EventsStats.write(later, to: url)
        }

        #expect(hits.count == 1, "the fault was never reached")
        #expect(written == false)
        #expect(try Data(contentsOf: url) == before)
        #expect(temps(under: dir).isEmpty)
    }

    // RED before the fix: `EventsStore.refresh` discarded the writer's Bool
    // (`_ = await EventsStats.write(…)`), so the counts file went stale —
    // and tools/publish_metrics kept publishing the old numbers — with
    // nothing said.
    @Test("the page: a refresh whose counts file cannot be published SAYS so, once per outage; the page still shows its plan; the old file stands")
    func aFailedCountsFileIsSaid() async throws {
        let dir = try F.scratchDirectory("eventsstats_page"); defer { try? FileManager.default.removeItem(at: dir) }
        let page = EventsStore(decisions: EventsDecisionStore(directory: dir))
        let model = VideoScanModel()
        model.records = [F.record("/Volumes/Tapes/Xmas/a.mov", caption: "A Christmas tree.")]
        await page.refresh(model: model)?.value                              // a first, healthy build
        let url = page.decisions.statsURL
        let before = try Data(contentsOf: url)
        let hits = FaultHits()

        // `refresh` saves from an unstructured Task, which inherits the hooks.
        await AtomicFilePublish.$hooks.withValue(.failing(.rename, errno: ENOSPC, onHit: { hits.hit() })) {
            await page.refresh(model: model)?.value
            await page.refresh(model: model)?.value
        }

        #expect(hits.count == 2, "both refreshes tried to publish")
        #expect(page.plan?.suggestions.count == 1, "the page is not hostage to its metrics file")
        #expect(try Data(contentsOf: url) == before, "the previous counts file stands")
        #expect(temps(under: dir).isEmpty)
        try? await Task.sleep(for: .milliseconds(400))                        // console flush debounce (150 ms)
        let said = model.dashboard.consoleLines.filter { $0.contains(EventsDecisionStore.statsFilename) && $0.contains("could not be written") }
        #expect(said.count == 1, "said once for the outage; the console holds: \(model.dashboard.consoleLines)")
        #expect(said.first?.contains("No space left on device") == true, "with the real reason")

        await page.refresh(model: model)?.value                              // the disk answers again
        #expect(hits.count == 2, "outside the scope the publish is live")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
