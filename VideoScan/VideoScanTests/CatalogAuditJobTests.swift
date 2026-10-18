// CatalogAuditJobTests.swift
// "Audit Catalog…" tier 0 (Rick 2026-10-15/16; design §6) — the five
// dimensions:
//   LOGIC     — every per-row outcome through the real job and real stats
//               (present / changed reported not marked / gone → Missing
//               through the engine / came back → live / still missing /
//               archived gone reported not marked / skipped rows); the
//               reason names the audit; EACCES and every errno but ENOENT
//               never mark; an unmounted root (at the start, or leaving
//               mid-run) never marks; a result for a row whose path or
//               marker changed meanwhile is dropped; save cadence; a save
//               that is not acknowledged undoes the marks and fails the run;
//               Stop is partial and saved; refusals; the words; the reason
//               decodes from an older catalog's JSON.
//   SCALE     — 100k rows on 10 drives planned and applied inside a budget.
//   ISOLATION — a poisoned / newer-schema catalog-audit.json is noise
//               (no crash, no mark, no line); a read-only catalog and the
//               shared store under a test host refuse before any stat; the
//               marker lives in the test catalog's folder.
//   SENSOR    — the audit's sources hold no file-moving / -removing /
//               -writing call, no Process(); its ONLY mark path is
//               stampRemoval / clearRemoval inside the model half; media is
//               byte-, inode- and mtime-identical after a run; one START and
//               one OUTCOME per run, stopped runs included.
// (No media matrix: the job never opens a media file — one stat per row.)

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Helpers

/// Shared with CatalogAuditRound2Tests.swift.
@MainActor
func runAudit(_ model: VideoScanModel,
                      marker: CatalogAuditRunMarker? = nil,
                      online: @escaping @Sendable (String) -> Bool = { _ in true },
                      laneRoot: @escaping @Sendable (String) -> String = CatalogAuditPlanner.productionLaneRoot,
                      configure: (CatalogAuditJob) -> Void = { _ in }) async -> CatalogAuditJob {
    let job = CatalogAuditJob(model: model, marker: marker)
    job.volumeOnline = online
    job.laneRoot = laneRoot
    job.tickMilliseconds = 20
    configure(job)
    await TestHostDrive.identified {
        job.start()
        await job.task?.value
    }
    return job
}

/// GitHub's hosted runner is a virtual Mac: DiskArbitration cannot identify
/// its disk, so the audit — rightly, refuse over guess (codex r5 P1) — stamps
/// nothing there, and every stamp test went red on CI (all of 2026-10-18).
/// On such a host only, the stamp tests run with a stand-in physical drive;
/// on the fleet they use the real one. "An unidentified drive gets no stamp"
/// stays pinned by CatalogAuditRound2Tests' own `unknown` override, which
/// this never replaces (a test's own override wins).
enum TestHostDrive {
    static let isUnidentified: Bool = {
        let tmp = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        var info = stat()
        guard stat(tmp, &info) == 0 else { return false }
        let unknown = DuplicateDrives.liveIdentityFresh(forPath: tmp, device: DeviceID.from(info.st_dev)).kind == .unknown
        print("[test-host-drive] \(tmp): drive \(unknown ? "NOT identified — stamp tests use a stand-in physical drive" : "identified")")
        return unknown
    }()

    private static let standIn: @Sendable (String, UInt64) -> DuplicateDrives.Identity = { _, device in
        .init(device: device, kind: .physical, physicalDevice: "test-host-\(device)")
    }

    private static var needed: Bool { isUnidentified && DuplicateDrives.lookupOverride == nil }

    static func identified<T>(_ body: () async throws -> T) async rethrows -> T {
        guard needed else { return try await body() }
        return try await DuplicateDrives.$lookupOverride.withValue(standIn) { try await body() }
    }

    static func identifiedSync<T>(_ body: () throws -> T) rethrows -> T {
        guard needed else { return try body() }
        return try DuplicateDrives.$lookupOverride.withValue(standIn) { try body() }
    }
}

/// Thread-safe call counter for the seams (≈ C++ std::atomic<int>).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

/// Shared with CatalogAuditRound2Tests.swift.
@MainActor
extension ShowAgainSandbox {
    /// A live row (no label) for a file written with `bytes` bytes, or
    /// not written at all. `seen` = an earlier audit saw the file on this
    /// sandbox's volume (D5: without that, a gone row is "never seen by an
    /// audit" and never marked).
    @discardableResult
    func live(_ name: String, bytes: Int = 2_000, onDisk: Bool = true, seen: Bool = false) throws -> VideoRecord {
        let r = try record(name, bytes: bytes, onDisk: onDisk, stage: .none)
        if seen { r.auditSeenOn = stamp }
        return r
    }

    /// A row already marked Missing by an earlier door.
    @discardableResult
    func missingRow(_ name: String, bytes: Int = 2_000, onDisk: Bool, seen: Bool = false) throws -> VideoRecord {
        let r = try live(name, bytes: bytes, onDisk: onDisk, seen: seen)
        VideoScanModel.stampRemoval(r, .missing(noticedAt: Date(timeIntervalSinceNow: -3_600), lastSeen: nil, reason: .missingOnDisk))
        return r
    }

    func auditMarkerFile() -> URL { catalogDir.appendingPathComponent(CatalogAuditRunMarker.fileName) }

    /// The persistent UUID of the volume the sandbox is on (the Data
    /// volume) — what the audit's handle reads through `fgetattrlist`.
    var volumeUUID: String { VolumeIdentity.uuid(forPath: files.path) ?? "NO-VOLUME-UUID" }

    /// The stamp an earlier audit would have left on a row it found here.
    var stamp: AuditSeenOn { AuditSeenOn(volumeUUID: volumeUUID, mountFrom: "sandbox", seenAt: Date(timeIntervalSinceNow: -86_400)) }

    /// The sandbox's `files` folder as a lane root of its own (the way a
    /// mounted /Volumes root is). Under D5 the lane root decides nothing
    /// about proof — only which rows share a lane and the "not asked"
    /// mount check. Paths elsewhere keep the production rule.
    var laneRoot: @Sendable (String) -> String {
        let root = files.path
        return { $0.hasPrefix(root + "/") ? root : CatalogAuditPlanner.productionLaneRoot($0) }
    }
}

// MARK: - Logic

@Suite("Audit catalog — logic", .serialized)
@MainActor
struct CatalogAuditJobLogicTests {

    @Test("every per-row outcome: present, changed (not marked), gone → Missing, came back → live, still missing, archived gone (not marked), skipped")
    func perRowOutcomes() async throws {
        let sb = try ShowAgainSandbox.make("ca_rows"); defer { sb.cleanup() }
        let present = try sb.live("present.mov")
        let changed = try sb.live("changed.mov", bytes: 2_000)
        changed.sizeBytes = 1_500                                    // the catalog remembers another size
        let gone = try sb.live("gone.mov", onDisk: false, seen: true)
        gone.contentHashAt = Date(timeIntervalSince1970: 1_700_000_000)
        let back = try sb.missingRow("back.mov", onDisk: true)
        let still = try sb.missingRow("still.mov", onDisk: false, seen: true)
        let archivedGone = try sb.live("arch_gone.mov", onDisk: false, seen: true)
        archivedGone.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 2_000)
        let trash = try sb.live("trash.mov", onDisk: false)
        VideoScanModel.stampRemoval(trash, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
        let removed = try sb.live("removed.mov")
        VideoScanModel.stampRemoval(removed, .removedFromCatalog(at: Date(), reason: .userRemoved))
        let superseded = try sb.live("old.mov", onDisk: false); superseded.supersededByID = UUID()
        let marker = CatalogAuditRunMarker()

        let job = await runAudit(sb.model, marker: marker)

        if case .finished(let summary) = job.state {
            #expect(summary.hasPrefix(job.totals.line) && summary.contains("gone under"), Comment(rawValue: summary))
        } else { Issue.record("expected finished, got \(job.state)") }
        #expect(job.totals.planned == 6 && job.totals.done == 6, Comment(rawValue: job.totals.line))
        #expect(job.totals[.present] == 1 && job.totals[.changed] == 1 && job.totals[.gone] == 1
                && job.totals[.cameBack] == 1 && job.totals[.stillMissing] == 1 && job.totals[.goneArchived] == 1,
                Comment(rawValue: job.totals.line))
        #expect(job.totals.skipped == [.inTrash: 1, .removedFromCatalog: 1, .superseded: 1])
        // The marks — through the engine, with the audit's reason.
        #expect(gone.removal?.state == .missing && gone.removal?.reason == .missingAtAudit)
        #expect(gone.removal?.lastSeen == gone.contentHashAt, "last seen = when the scan last hashed it")
        #expect(gone.lifecycleStage == .cataloged, "Missing writes no legacy stage")
        #expect(back.removal == nil, "a Missing row whose file is back is live again")
        // Reported, never marked.
        #expect(present.removal == nil && changed.removal == nil && archivedGone.removal == nil)
        #expect(still.removal?.reason == .missingOnDisk, "an existing Missing marker is left exactly as it was")
        #expect(trash.removal?.state == .inTrash && removed.removal?.state == .removedFromCatalog)
        #expect(job.storedCount == 2 && job.saveCount >= 1 && !job.saveFailed)
        // Every file found got the where-seen stamp (D5), the others none.
        #expect(present.auditSeenOn?.volumeUUID == sb.volumeUUID && changed.auditSeenOn != nil && back.auditSeenOn != nil)
        #expect(gone.auditSeenOn?.volumeUUID == sb.volumeUUID && trash.auditSeenOn == nil && removed.auditSeenOn == nil)
        #expect(job.stampedCount == 3, "present, changed and came back were stamped (got \(job.stampedCount))")
        // The detail rows carry the reasons.
        #expect(job.problems.first { $0.path == changed.fullPath }?.detail.contains("the catalog says") == true)
        #expect(job.problems.first { $0.path == archivedGone.fullPath }?.detail.contains("Verify Archive") == true)
        #expect(job.sample.map(\.path) == [present.fullPath])
        // The OUTCOME names the counts and the folder that lost files.
        let text = sb.catalogLogText()
        #expect(text.contains("Audit catalog: OUTCOME — ") && text.contains("1 gone — marked Missing") && text.contains("2 gone under \(sb.files.path)"),
                Comment(rawValue: text))
        #expect(!text.contains("partial"))
        // The marker file: counts, outcome, not partial.
        let last = try #require(marker.lastRun)
        #expect(last.outcome == .completed && !last.partial && last.marked == 2 && last.counts["gone"] == 1 && last.counts["planned"] == 6)
        #expect(marker.fileURL == sb.auditMarkerFile() && FileManager.default.fileExists(atPath: sb.auditMarkerFile().path))
        // The real save reached catalog.json: a reloaded catalog carries the mark and the restore.
        let reloaded = CatalogStore(directory: sb.catalogDir).load()
        #expect(reloaded.first { $0.id == gone.id }?.removal?.reason == .missingAtAudit)
        #expect(reloaded.first { $0.id == back.id }?.removal == nil)
        let onDisk = reloaded.first { $0.id == present.id }?.auditSeenOn
        #expect(onDisk?.volumeUUID == present.auditSeenOn?.volumeUUID && onDisk?.mountFrom == present.auditSeenOn?.mountFrom
                && abs((onDisk?.seenAt.timeIntervalSince1970 ?? 0) - (present.auditSeenOn?.seenAt.timeIntervalSince1970 ?? 1)) < 1,
                "the stamp went to disk with the marks (catalog.json keeps whole seconds): \(String(describing: onDisk))")
    }

    @Test("a catalog size of 0 is unknown: the file is present, never 'changed'")
    func zeroCatalogSizeIsNotCompared() async throws {
        let sb = try ShowAgainSandbox.make("ca_zero"); defer { sb.cleanup() }
        let r = try sb.live("z.mov", bytes: 10); r.sizeBytes = 0
        let job = await runAudit(sb.model)
        #expect(job.totals[.present] == 1 && job.totals[.changed] == 0, Comment(rawValue: job.totals.line))
    }

    @Test("never marks on EACCES — or any errno but ENOENT/ENOTDIR (invariant 2)")
    func neverMarksOnEACCES() async throws {
        let sb = try ShowAgainSandbox.make("ca_eacces"); defer { sb.cleanup() }
        let a = try sb.live("a.mov", onDisk: false)
        let b = try sb.live("b.mov", onDisk: false)
        let c = try sb.live("c.mov", onDisk: false)
        let back = try sb.missingRow("back.mov", onDisk: false)
        let errnos: [String: Int32] = [a.fullPath: EACCES, b.fullPath: EIO, c.fullPath: ETIMEDOUT, back.fullPath: EPERM]
        let job = await runAudit(sb.model) { j in
            j.statPaths = { paths in paths.map { .unreadable(errno: errnos[$0] ?? EACCES) } }
        }
        #expect(job.totals[.couldNotCheck] == 4 && job.totals[.gone] == 0 && job.totals[.cameBack] == 0, Comment(rawValue: job.totals.line))
        #expect(a.removal == nil && b.removal == nil && c.removal == nil, "an unreadable path is never a gone file")
        #expect(back.removal?.state == .missing, "and never a returned one")
        #expect(job.storedCount == 0 && job.saveCount == 0, "nothing to save")
        #expect(job.problems.first { $0.path == a.fullPath }?.detail.contains("EACCES") == true)
        if case .finished = job.state {} else { Issue.record("expected finished, got \(job.state)") }
    }

    @Test("a path that is a folder now is 'could not check', never marked")
    func notAFileIsNotGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_dir"); defer { sb.cleanup() }
        let r = try sb.live("was_a_file.mov", onDisk: false)
        try FileManager.default.createDirectory(atPath: r.fullPath, withIntermediateDirectories: true)
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil)
    }

    @Test("never marks when the root is unmounted — at the start (not asked) or when the drive leaves mid-run (invariant 1)")
    func neverMarksWhenRootUnmounted() async throws {
        // (i) Not mounted at the start: not asked, never stat'ed.
        let sb = try ShowAgainSandbox.make("ca_unmounted"); defer { sb.cleanup() }
        let offlineRoot = "/Volumes/CAUnmounted_\(UUID().uuidString.prefix(8))"
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/away.mov"; away.filename = "away.mov"; away.sizeBytes = 3_000; away.directory = offlineRoot
        sb.model.records.append(away)
        let here = try sb.live("here.mov")
        let stats = CallCounter()
        let first = await runAudit(sb.model, online: { !$0.hasPrefix(offlineRoot) }) { j in
            let real = j.statPaths
            j.statPaths = { paths in _ = stats.next(); #expect(!paths.contains { $0.hasPrefix(offlineRoot) }, "an unmounted root is never stat'ed"); return real(paths) }
        }
        #expect(first.totals[.notAsked] == 1 && first.totals[.present] == 1, Comment(rawValue: first.totals.line))
        #expect(away.removal == nil, "a row on an unmounted drive is never marked")
        #expect(first.lanes.first { $0.root == offlineRoot }?.phase == .disconnected)
        _ = here

        // (ii) Mounted when planned, gone before the answers land: every
        // stat reads ENOENT, and NOTHING is marked.
        let sb2 = try ShowAgainSandbox.make("ca_left"); defer { sb2.cleanup() }
        let rows = try (0..<4).map { try sb2.live("left\($0).mov", onDisk: false) }
        let probes = CallCounter()
        let second = await runAudit(sb2.model, online: { _ in probes.next() == 1 })
        #expect(second.totals[.notAsked] == 4 && second.totals[.gone] == 0, Comment(rawValue: second.totals.line))
        #expect(rows.allSatisfy { $0.removal == nil }, "a drive that left mid-run marks nothing")
        #expect(second.lanes.first?.phase == .disconnected)
        #expect(second.storedCount == 0)
        #expect(sb2.catalogLogText().contains("the drive went away"))
    }

    @Test("a result is applied only to the row it asked about: a changed path or marker meanwhile drops it (invariant 4)")
    func resultDroppedWhenRowChangedMeanwhile() throws {
        let sb = try ShowAgainSandbox.make("ca_cas"); defer { sb.cleanup() }
        let moved = try sb.live("moved.mov", onDisk: false)
        let marked = try sb.live("marked.mov", onDisk: false)
        let restored = try sb.missingRow("restored.mov", onDisk: true)
        let deleted = try sb.live("deleted.mov", onDisk: false)
        let plan = sb.model.catalogAuditPlan()
        let item = { (r: VideoRecord) in plan.lanes.flatMap(\.items).first { $0.id == r.id }! }
        let movedItem = item(moved), markedItem = item(marked), restoredItem = item(restored), deletedItem = item(deleted)

        moved.fullPath = sb.files.appendingPathComponent("elsewhere.mov").path              // rescanned to a new path
        VideoScanModel.stampRemoval(marked, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))   // another door
        _ = sb.model.clearRemoval(restored)                                                  // Restore clicked meanwhile
        sb.model.records.removeAll { $0.id == deleted.id }                                   // row left the catalog

        for (stat, it) in [(CatalogAuditStat.gone, movedItem), (.gone, markedItem), (.file(size: 2_000), restoredItem), (.gone, deletedItem)] {
            let (apply, mark) = sb.model.applyCatalogAudit(stat, to: it)
            #expect(apply.result == .recordChanged && mark == nil, "\(it.filename): \(apply.result)")
        }
        #expect(moved.removal == nil && marked.removal?.state == .inTrash && restored.removal == nil)
    }

    @Test("an acknowledged save every N marks and at the end; the clock alone saves too")
    func saveCadence() async throws {
        let sb = try ShowAgainSandbox.make("ca_saveN"); defer { sb.cleanup() }
        for i in 0..<5 { try sb.live("g\(i).mov", onDisk: false, seen: true) }
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot) { j in
            j.checkpointRows = 2
            j.checkpointSeconds = 3_600
            j.chunkSize = 1
            j.saveCatalogForTesting = { true }
        }
        #expect(job.storedCount == 5 && job.totals[.gone] == 5)
        #expect(job.saveCount == 3, "after 2, after 4, and the final one for the 5th (got \(job.saveCount))")

        let sb2 = try ShowAgainSandbox.make("ca_saveT"); defer { sb2.cleanup() }
        for i in 0..<3 { try sb2.live("t\(i).mov", onDisk: false, seen: true) }
        let clock = await runAudit(sb2.model, laneRoot: sb2.laneRoot) { j in
            j.checkpointRows = 10_000
            j.checkpointSeconds = 0
            j.chunkSize = 1
            j.statPaths = { paths in Thread.sleep(forTimeInterval: 0.05); return paths.map { _ in .gone } }
            j.saveCatalogForTesting = { true }
        }
        #expect(clock.storedCount == 3 && clock.saveCount >= 2, "time-based checkpoints fired (got \(clock.saveCount))")
    }

    @Test("a save that is not acknowledged undoes the unsaved marks (compare-and-set) and fails the run")
    func failedSaveUndoesMarks() async throws {
        let sb = try ShowAgainSandbox.make("ca_savefail"); defer { sb.cleanup() }
        let gone = try (0..<3).map { try sb.live("s\($0).mov", onDisk: false, seen: true) }
        let back = try sb.missingRow("back.mov", onDisk: true)
        let kept = try sb.live("kept.mov", onDisk: false, seen: true)
        let marker = CatalogAuditRunMarker()
        let job = await runAudit(sb.model, marker: marker) { j in
            j.chunkSize = 1
            j.checkpointRows = 100
            j.saveCatalogForTesting = { false }
        }
        if case .failed(let msg) = job.state { #expect(msg.contains("could not be saved"), Comment(rawValue: msg)) } else { Issue.record("expected failed, got \(job.state)") }
        #expect(job.saveFailed && job.storedCount == 0)
        #expect(gone.allSatisfy { $0.removal == nil } && kept.removal == nil, "every unsaved mark is undone")
        #expect(back.removal?.state == .missing && back.removal?.reason == .missingOnDisk, "the restore is undone exactly")
        #expect(marker.lastRun?.outcome == .failed && marker.lastRun?.partial == true)
        let text = sb.catalogLogText()
        #expect(text.contains("NOT confirmed") && text.contains("OUTCOME failed (partial)"))
        // The undo is compare-and-set: a row that moved on keeps what it has now.
        let plan = sb.model.catalogAuditPlan()
        let item = plan.lanes.flatMap(\.items).first { $0.id == kept.id }!
        let (_, mark) = sb.model.applyCatalogAudit(.gone, to: item)
        VideoScanModel.stampRemoval(kept, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
        let reverted = sb.model.revertCatalogAuditMark(try #require(mark))
        #expect(reverted == false)
        #expect(kept.removal?.state == .inTrash)
    }

    @Test("Stop finishes the chunk in flight, saves the marks so far, and says partial", .timeLimit(.minutes(1)))
    func stopIsPartialAndSaved() async throws {
        let sb = try ShowAgainSandbox.make("ca_stop"); defer { sb.cleanup() }
        let rows = try (0..<12).map { try sb.live("stop\($0).mov", onDisk: false, seen: true) }
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
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(job.totals.done > 0 && job.totals.done < 12, "stopped part-way (\(job.totals.done))")
        #expect(job.storedCount == job.totals[.gone], "every mark made was saved")
        #expect(rows.filter { $0.removal != nil }.count == job.storedCount, "no row carries an unsaved mark")
        #expect(marker.lastRun?.outcome == .stopped && marker.lastRun?.partial == true)
        #expect(sb.catalogLogText().contains("OUTCOME stopped (partial)"))
    }

    @Test("the reason decodes from an older catalog's JSON, and an unknown reason still decodes")
    func reasonDecodesFromOldJSON() throws {
        let decoder = JSONDecoder()
        let audit = try decoder.decode(RemovalMarker.self, from: Data(#"{"state":"missing","since":1700000000,"reason":"missingAtAudit","lastSeen":1690000000}"#.utf8))
        #expect(audit.state == .missing && audit.reason == .missingAtAudit && audit.lastSeen != nil)
        let older = try decoder.decode(RemovalMarker.self, from: Data(#"{"state":"missing","since":1700000000,"reason":"missingOnDisk"}"#.utf8))
        #expect(older.reason == .missingOnDisk && older.reason != .missingAtAudit)
        let newer = try decoder.decode(RemovalMarker.self, from: Data(#"{"state":"missing","since":1700000000,"reason":"missingAtSomethingNewer"}"#.utf8))
        #expect(newer.reason.rawValue == "missingAtSomethingNewer")
        #expect(RemovalReason.missingAtAudit.rawValue == "missingAtAudit", "the on-disk key is pinned")
        // Round trip through the marker's own encoder (the catalog's round
        // trip through catalog.json is pinned in perRowOutcomes).
        let written = RemovalMarker.missing(noticedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil, reason: .missingAtAudit)
        let roundTripped = try decoder.decode(RemovalMarker.self, from: try JSONEncoder().encode(written))
        #expect(roundTripped == written)
    }

    @Test("the words: the line, the folders that lost the most files, skipped")
    func words() {
        var t = CatalogAuditTotals()
        t.planned = 10
        t.add(.present, rows: 6); t.add(.gone, rows: 3); t.add(.changed)
        t.skipped = [.inTrash: 2, .superseded: 1]
        for p in ["/Volumes/P/_staging/a.mov", "/Volumes/P/_staging/b.mov", "/Volumes/Q/x/c.mov"] { t.noteGone(path: p) }
        #expect(t.line == "6 of 10 present · 1 changed size (reported, not marked) · 3 gone — marked Missing · 3 skipped (in the Trash 2, superseded 1)", Comment(rawValue: t.line))
        #expect(t.topFolders().map(\.folder) == ["/Volumes/P/_staging", "/Volumes/Q/x"])
        #expect(t.goneFoldersClause == "2 gone under /Volumes/P/_staging; 1 gone under /Volumes/Q/x", Comment(rawValue: t.goneFoldersClause))
        for i in 0..<5 { t.noteGone(path: "/Volumes/R/f\(i)/g.mov") }
        #expect(t.goneFoldersClause.hasSuffix("; 4 more in 4 other folder(s)"), Comment(rawValue: t.goneFoldersClause))
        #expect(t.marked == 3)
        #expect(CatalogAuditResult.gone.isMark && CatalogAuditResult.cameBack.isMark && !CatalogAuditResult.changed.isMark)
    }

    @Test("the plan: live rows and Missing rows are asked; Trash, removed, superseded and pathless rows are skipped; one lane per root in path order")
    func planShape() throws {
        let sb = try ShowAgainSandbox.make("ca_plan"); defer { sb.cleanup() }
        try sb.live("b.mov"); try sb.live("a.mov")
        try sb.missingRow("m.mov", onDisk: false)
        let t = try sb.live("t.mov"); VideoScanModel.stampRemoval(t, .inTrash(movedAt: Date(), trashPath: nil, reason: .junk))
        let x = try sb.live("x.mov"); VideoScanModel.stampRemoval(x, .removedFromCatalog(at: Date(), reason: .userRemoved))
        let s = try sb.live("s.mov"); s.supersededByID = UUID()
        let p = VideoRecord(); sb.model.records.append(p)
        let ext = VideoRecord(); ext.fullPath = "/Volumes/CAPlan/clip.mov"; ext.filename = "clip.mov"; sb.model.records.append(ext)
        let plan = sb.model.catalogAuditPlan()
        #expect(plan.lanes.map(\.root) == ["/", "/Volumes/CAPlan"])
        #expect(plan.lanes[0].items.map(\.filename) == ["a.mov", "b.mov", "m.mov"])
        #expect(plan.lanes[0].items.last?.wasMissing == true && plan.missingRecheck == 1)
        #expect(plan.skipped == [.inTrash: 1, .removedFromCatalog: 1, .superseded: 1, .noPath: 1])
        #expect(plan.rowCount == 4 && plan.skippedCount == 4)
    }
}

// MARK: - Scale

@Suite("Audit catalog — scale (100k rows)", .serialized)
@MainActor
struct CatalogAuditJobScaleTests {

    /// 100k rows in 100 real folders of the sandbox (the 10 gone ones must
    /// be PROVEN gone at the mark, on a real filesystem — a fake /Volumes
    /// root can never be), 1 in 10,000 gone, applied through the real job
    /// with a stubbed first-pass stat and an acknowledged-save seam.
    /// Budget (Debug, M4 Max, headroom ×3+): plan < 2 s; plan + run < 10 s.
    @Test(.timeLimit(.minutes(2)))
    func planAndRunAt100k() async throws {
        let sb = try ShowAgainSandbox.make("ca_scale"); defer { sb.cleanup() }
        for d in 0..<100 {
            try FileManager.default.createDirectory(at: sb.files.appendingPathComponent("d\(d)"), withIntermediateDirectories: true)
        }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = sb.files.appendingPathComponent("d\(i % 100)/clip_\(i).mov").path
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i)
            if i % 10_000 == 0 { r.auditSeenOn = sb.stamp }                    // the gone ones were seen by an earlier audit
            records.append(r)
        }
        sb.model.records = records
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var plan = CatalogAuditPlan()
        let planned = clock.measure { plan = sb.model.catalogAuditPlan() }
        #expect(plan.lanes.count == 1 && plan.rowCount == 100_000)
        expectWithinTimingBudget("audit plan over 100k rows", measured: planned,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)

        let start = clock.now
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot) { j in
            j.statPaths = { paths in
                paths.map { p in
                    let n = Int(p.split(separator: "_").last!.dropLast(4)) ?? -1
                    return n % 10_000 == 0 ? .gone : .file(size: Int64(10_000 + n))
                }
            }
            j.saveCatalogForTesting = { true }
        }
        let ran = clock.now - start
        #expect(job.totals.done == 100_000 && job.totals[.gone] == 10 && job.totals[.present] == 99_990, Comment(rawValue: job.totals.line))
        #expect(job.storedCount == 10 && job.sample.count == CatalogAuditJob.sampleCap)
        #expect(records.filter { $0.removal != nil }.count == 10)
        expectWithinTimingBudget("audit plan + run over 100k rows", measured: planned + ran,
                                 budget: PerformanceLane.debugCeiling(.seconds(10)), loadBefore: load)
    }
}

// MARK: - Isolation

@Suite("Audit catalog — isolation: poisoned marker, refusals", .serialized)
@MainActor
struct CatalogAuditJobIsolationTests {

    @Test("a poisoned or newer-schema catalog-audit.json is read-only noise: no crash, no mark, no launch line; the run then rewrites it")
    func poisonedMarkerIsNoise() async throws {
        let sb = try ShowAgainSandbox.make("ca_poison"); defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        let file = sb.auditMarkerFile()
        for poison in ["{ not json", #"{"startedAt":"2026-10-16T02:00:00Z","outcome":"somethingNewer","schema":9,"counts":{"gone":99999}}"#, ""] {
            try Data(poison.utf8).write(to: file)
            let marker = CatalogAuditRunMarker()
            #expect(marker.attach(catalogFile: sb.model.catalogStore.fileLocation) == nil, Comment(rawValue: poison))
            #expect(marker.lastRun == nil)
        }
        #expect(CatalogAuditRunMarker.launchLine(CatalogAuditRunRecord(startedAt: Date(), finishedAt: Date(), outcome: .completed)) == nil,
                "a clean completed run says nothing at launch")
        let live = try sb.live("ok.mov")
        let marker = CatalogAuditRunMarker()
        let job = await runAudit(sb.model, marker: marker)
        #expect(job.totals[.present] == 1 && live.removal == nil)
        #expect(marker.lastRun?.outcome == .completed, "the run's own marker replaces the poison")
        #expect(marker.fileURL?.path.hasPrefix(sb.root.path) == true, "never the real Application Support marker")
    }

    @Test("a read-only catalog refuses before any stat; nothing is marked or saved")
    func readOnlyRefusesBeforeAnyStat() async throws {
        let sb = try ShowAgainSandbox.make("ca_ro"); defer { sb.cleanup() }
        let gone = try sb.live("gone.mov", onDisk: false)
        sb.model.isReadOnly = true
        let stats = CallCounter()
        let marker = CatalogAuditRunMarker()
        let job = await runAudit(sb.model, marker: marker) { j in
            j.statPaths = { paths in _ = stats.next(); return paths.map { _ in .gone } }
        }
        #expect(job.wasRefused)
        if case .failed(let msg) = job.state { #expect(msg.contains("read-only"), Comment(rawValue: msg)) } else { Issue.record("expected refused, got \(job.state)") }
        #expect(stats.value == 0, "no stat ran")
        #expect(gone.removal == nil && job.storedCount == 0 && job.saveCount == 0)
        #expect(sb.catalogLogText().contains("Audit catalog: refused"))
        #expect(!FileManager.default.fileExists(atPath: sb.auditMarkerFile().path), "a refused run writes no marker")
    }

    @Test("the shared App Support store refuses from a test host")
    func sharedStoreRefusesUnderTestHost() async throws {
        let model = VideoScanModel(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_ca_shared_\(UUID().uuidString.prefix(8))", isDirectory: true))
        #expect(model.catalogStore === CatalogStore.shared)
        let stats = CallCounter()
        let job = await runAudit(model) { j in j.statPaths = { paths in _ = stats.next(); return paths.map { _ in .gone } } }
        #expect(job.wasRefused && stats.value == 0)
        if case .failed(let msg) = job.state { #expect(msg.contains("shared one"), Comment(rawValue: msg)) } else { Issue.record("\(job.state)") }
    }

    @Test("a second run while one is active is refused by the Center; nothing starts")
    func secondRunRefused() async throws {
        let sb = try ShowAgainSandbox.make("ca_twice"); defer { sb.cleanup() }
        try sb.live("a.mov")
        let center = MediaFileOperationsCenter()
        let first = center.startCatalogAudit(model: sb.model, marker: nil)
        let second = center.startCatalogAudit(model: sb.model, marker: nil)
        #expect(second.wasRefused)
        await first.task?.value
        await second.task?.value
        if case .finished = first.state {} else { Issue.record("\(first.state)") }
    }
}

// MARK: - Sensor

@Suite("Audit catalog — sensor: one mark path, nothing on media", .serialized)
@MainActor
struct CatalogAuditJobSensorTests {

    static let modelHalf = "VideoScanModel+CatalogAudit.swift"
    static let sources = [
        "CatalogAuditPlan.swift", "CatalogAuditJob.swift", "CatalogAuditRun.swift", "CatalogAuditDetailView.swift",
        "CatalogAuditMenuItem.swift", "CatalogAuditCLI.swift", modelHalf,
    ]

    static func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("no file-moving, -removing or -writing call, no Process(), no row removal, no direct marker write in the audit's sources")
    func sourcesTouchNoFileAndNoRow() throws {
        let forbidden = CheckCopiesSensorTests.forbidden + ["analyzeDuplicates", "purge", "setAside(", "Process()", "Process(", "posix_spawn",
                                                          "records.remove"]
        // Assignments, not comparisons (OneEngineSensorTests' own patterns).
        let writes = [#"\.removal\s*=[^=]"#, #"\.purgedAt\s*=[^=]"#, #"lifecycleStage\s*=[^=]"#, #"archiveStage\s*=[^=]"#]
        for name in Self.sources {
            let code = try Self.code(name)
            for call in forbidden { #expect(!code.contains(call), "\(name) contains \(call)") }
            for pattern in writes {
                #expect(code.range(of: pattern, options: .regularExpression) == nil, "\(name) writes a marker field directly (\(pattern))")
            }
        }
    }

    @Test("the ONLY mark path is stampRemoval / clearRemoval inside the model half, and the job reaches rows only through it")
    func onlyOneMarkPath() throws {
        for name in Self.sources where name != Self.modelHalf {
            let code = try Self.code(name)
            for call in ["stampRemoval", "clearRemoval", "RemovalUndo", "RemovalMarker.missing", ".reinstate("] {
                #expect(!code.contains(call), "\(name) reaches the marker through \(call) — only \(Self.modelHalf) may")
            }
        }
        let half = try Self.code(Self.modelHalf)
        #expect(half.components(separatedBy: "stampRemoval(").count == 2, "exactly one stampRemoval call")
        #expect(half.components(separatedBy: "clearRemoval(").count == 2, "exactly one clearRemoval call")
        #expect(half.contains("reason: .missingAtAudit"))
        let job = try Self.code("CatalogAuditJob.swift")
        #expect(job.contains("model.applyCatalogAudit(observation.stat, seenOn: observation.seenOn, to: item)") && job.contains("model.revertCatalogAuditMark(mark)"))
        #expect(job.contains("if observations.contains(where: { $0.stat == .gone }), !volumeOnline(lane.root)"), "the fresh mount check before any gone answer lands")
        #expect(job.contains("saveCatalogAcknowledged(asHoldOwner: writeHoldOwner)"), "marks land only after an acknowledged save")
        let plan = try Self.code("CatalogAuditPlan.swift")
        #expect(plan.contains("(e == ENOENT || e == ENOTDIR) ? .gone : .unreadable(errno: e)"), "only ENOENT / ENOTDIR mean gone")
        try Self.expectProofAtTheMark(half: half, plan: plan, job: job)
        // The only file written: catalog-audit.json, through AtomicFilePublish, in the run marker.
        for name in Self.sources where name != "CatalogAuditRun.swift" {
            let other = try Self.code(name)
            #expect(!other.contains("AtomicFilePublish"), "\(name) writes a file")
        }
        let run = try Self.code("CatalogAuditRun.swift")
        #expect(run.contains("AtomicFilePublish.write(data, to: fileURL"))
    }

    /// PROVE AT THE MARK (codex 2026-10-16; r2; r3): the apply path walks
    /// the path again synchronously, through a directory handle, before the
    /// one `stampRemoval`, under THE ONE RULE (D5: the handle's volume UUID
    /// equals the stamp read from the LIVE record; no stamp → never seen,
    /// never marked) with the D6 checks (lstat for a link anywhere in the
    /// existing path; after the ENOENT the handle still names its path);
    /// the guard compares the whole planned snapshot (supersession and the
    /// stamp included); "archived" is read from the live record; rollback
    /// is by value AND revision (no object memento); a failed save ends
    /// failed even after Stop; the superseded lane-root identity and "/"
    /// stub heuristics are gone.
    static func expectProofAtTheMark(half: String, plan: String, job: String) throws {
        let proof = try #require(half.range(of: "CatalogAuditProof.atTheMark(item, lastSeenOn: rec.auditSeenOn"),
                                 "the second look is taken in the model half, against the LIVE record's stamp")
        let mark = try #require(half.range(of: "stampRemoval("))
        #expect(proof.lowerBound < mark.lowerBound, "the second look comes before the one stampRemoval call")
        #expect(!half.contains("await "), "the proof and the mark are one synchronous step on the main actor")
        #expect(half.contains("CatalogAuditRowSnapshot.of(rec) == item.planned"), "the guard compares the planned snapshot")
        #expect(half.contains("CatalogAuditPlanner.isArchived(rec)"), "archived is read from the LIVE record")
        for memento in ["RemovalUndo", ".reinstate("] { #expect(!half.contains(memento), "rollback holds no object memento (\(memento))") }
        #expect(half.contains("Self.revertRemoval(rec, wrote: mark.wrote, previous: mark.previous, revision: mark.revision"),
                "rollback is by value AND revision, on the current instance (r2 F4)")
        #expect(half.contains("revision: rec.removalRevision"), "the mark records the revision its write produced")
        #expect(half.components(separatedBy: "rec.auditSeenOn = seenOn").count == 2, "the stamp is written in exactly one place, in the model half")
        // The walk (r2 F2): every open is a read-only DIRECTORY handle with the link not followed; the name is read through it.
        #expect(plan.contains("static let directoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"))
        #expect(plan.components(separatedBy: "open(path, directoryFlags)").count == 2, "one open, with the directory flags")
        #expect(plan.components(separatedBy: "openat(fd, name, directoryFlags)").count == 2, "one openat, with the directory flags")
        #expect(plan.contains("CatalogAuditMountIdentity.of(fd: fd)"), "the identity is the handle's (fstatfs + the volume UUID), never a pathname's")
        #expect(plan.contains("VolumeIdentity.uuid(forDescriptor: fd, path: nil)"), "the volume UUID is read through the handle")
        for pathname in ["realpath(", "statfs(item", "CatalogAuditStat.of(item.path)", "ofLaneRoot", "stubRule", "hasEntries", "expectedMount"] {
            #expect(!plan.contains(pathname), "the proof resolves no pathname and keeps no superseded rule (\(pathname))")
        }
        // D6 (r3 F2): every existing component looked at with the link not followed; after the ENOENT the handle still names its path.
        #expect(plan.contains("if let refusal = linkInTheExistingPath(root: root, folders: folders) { return refusal }"))
        #expect(plan.contains("lstat(pathOf(root, folders[..<k]), &sb)") && plan.contains("if (sb.st_mode & S_IFMT) == S_IFLNK { return .link }"))
        #expect(plan.contains("guard stillNames(path, fd) else { return .changedUnderTheAudit }"))
        #expect(plan.contains("guard fstat(fd, &held) == 0, lstat(path, &named) == 0 else { return false }"))
        #expect(plan.components(separatedBy: "fstatat(fd, name, &sb, AT_SYMLINK_NOFOLLOW)").count == 3,
                "the name AND a folder that would not open are both looked at through the handle, link not followed")
        // D9 (r4 F2): after the open — O_NOFOLLOW guards only the last component — the lexical walk again and the handle
        // must name its path, in the proof AND in the first pass's stamp acquisition, before anything is read through it.
        #expect(plan.contains("if let refusal = boundToItsPath(root: root, folders: folders, path: path, fd: fd) { return refusal }"),
                "the proof binds the opened handle to its pathname before the descent")
        #expect(plan.contains("boundToItsPath(root: root, folders: folders, path: path, fd: fd) == nil,"),
                "seenOn binds the opened handle to its pathname before the identity and the names are read")
        #expect(plan.contains("return stillNames(path, fd) ? nil : .changedUnderTheAudit"), "the binding is the walk again, then stillNames")
        // THE ONE RULE (r3 F1, D5): no stamp → never seen; the handle's volume UUID must equal the stamp's.
        #expect(plan.contains("guard let lastSeenOn else { return .neverSeenByAnAudit }"))
        #expect(plan.contains("guard uuid == lastSeenOn.volumeUUID else {"))
        // D8 (r4 F1): the physical device, asked for the handle's own mount through Delete Duplicates' one DiskArbitration
        // helper; a stamp that names a drive is held to it, one without proves by volume UUID alone.
        #expect(plan.contains("DuplicateDrives.deviceIdentification(mountFrom: from, isLocal: isLocal,")
                && plan.contains("deviceKey: drive.key, deviceIdentified: drive.identified)")
                && plan.contains("guard deviceIdentified else { return nil }"),
                "r5 P1: the device key is asked for the handle's f_mntfromname in the one identity read, the identity says whether the drive was identified, and an unidentified local drive gets no stamp")
        #expect(plan.contains("guard let stampedDrive = lastSeenOn.deviceKey else { return .gone }")
                && plan.contains("guard let drive = on.deviceKey else {") && plan.contains("guard drive == stampedDrive else {"))
        #expect(plan.contains("AuditSeenOn(volumeUUID: $0, mountFrom: mountFrom, seenAt: now, deviceKey: deviceKey)"), "the stamp carries the drive")
        #expect(plan.contains("auditSeenOn: r.auditSeenOn") && plan.contains("supersededByID: r.supersededByID"),
                "the snapshot carries the stamp (r3 D5) and supersession (r2 F3)")
        #expect(!plan.contains("isArchived: Bool"), "the item carries no planned 'archived' flag to trust")
        #expect(!job.contains("CatalogAuditMountIdentity"), "the job anchors nothing: the lane root is only the mount check")
        #expect(job.contains("finish(failedSave: message)") && !job.contains("finish(failed: message)"),
                "a save that is not acknowledged ends failed, Stop or not (failed > stopped > completed)")
    }

    /// MOPS-14's one declared exception to "nothing opened": a DIRECTORY
    /// handle, read-only, in CatalogAuditPlan.swift and nowhere else in the
    /// audit (with `lstat` / `fstat` for the D6 checks there too); no audit
    /// source opens anything for writing or moves a thing.
    @Test("the directory-handle calls live in CatalogAuditPlan.swift only; no audit source writes, renames, unlinks or opens for writing")
    func directoryHandleIsTheOnlyOpenAndOnlyInThePlan() throws {
        let handleCalls = ["open(", "openat(", "fstatat(", "fstatfs(", "lstat(", "fstat("]
        let writes = ["O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND", "FileHandle(forWritingTo", "FileHandle(forUpdating",
                      "unlink(", "unlinkat(", "rename(", "renameat(", "rmdir(", "mkdir(", "mkdirat(", "truncate(", "ftruncate(",
                      "symlink(", "link(", "chmod(", "fchmod(", "utimes(", "futimes("]
        for name in Self.sources {
            let code = try Self.code(name)
            for call in writes { #expect(!code.contains(call), "\(name) contains \(call)") }
            for da in ["DiskArbitration", "DASession", "DADisk"] {
                #expect(!code.contains(da), "\(name) talks to DiskArbitration (\(da)) — only DuplicateDrives.physicalDeviceKey may (D8)")
            }
            if name == "CatalogAuditPlan.swift" { continue }
            for call in handleCalls { #expect(!code.contains(call), "\(name) opens a handle (\(call)) — only CatalogAuditPlan.swift may") }
        }
        let plan = try Self.code("CatalogAuditPlan.swift")
        for call in handleCalls { #expect(plan.contains(call), "the walk uses \(call)") }
        #expect(plan.components(separatedBy: "open(").count == 2 && plan.components(separatedBy: "openat(").count == 2,
                "exactly one open and one openat")
        #expect(plan.components(separatedBy: "lstat(").count == 3 && plan.components(separatedBy: "fstat(").count == 2,
                "two lstat (the link pre-check, the post-ENOENT check) and one fstat (the post-ENOENT check)")
        for gone in ["fdopendir(", "readdir(", "dup("] { #expect(!plan.contains(gone), "the stub rule's listing is gone (\(gone))") }
    }

    @Test("every file is still at its path with the same bytes, inode and mtime after a run; nothing appeared beside the media")
    func filesUntouched() async throws {
        let sb = try ShowAgainSandbox.make("ca_untouched"); defer { sb.cleanup() }
        let recs = try (0..<4).map { try sb.live("ro\($0).mov", bytes: 3_000 + $0) }
        let back = try sb.missingRow("back.mov", bytes: 777, onDisk: true)
        let before = try (recs + [back]).map { try MediaFingerprint.of($0.fullPath) }
        let job = await runAudit(sb.model)
        #expect(job.totals[.present] == 4 && job.totals[.cameBack] == 1)
        #expect(try (recs + [back]).map { try MediaFingerprint.of($0.fullPath) } == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: sb.files.path).sorted()
        #expect(names == (recs + [back]).map(\.filename).sorted(), "nothing appeared beside the media")
    }

    @Test("exactly one START and one OUTCOME line per run, including a stopped and a refused one")
    func oneStartOneOutcome() async throws {
        let sb = try ShowAgainSandbox.make("ca_lines"); defer { sb.cleanup() }
        try sb.live("l.mov")
        _ = await runAudit(sb.model)
        var text = sb.catalogLogText()
        #expect(text.components(separatedBy: "Audit catalog: START").count == 2)
        #expect(text.components(separatedBy: "Audit catalog: OUTCOME").count == 2)
        let job = CatalogAuditJob(model: sb.model)
        job.volumeOnline = { _ in true }
        job.statPaths = { paths in Thread.sleep(forTimeInterval: 0.2); return paths.map { _ in .file(size: 2_000) } }
        job.start()
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await job.task?.value
        text = sb.catalogLogText()
        #expect(text.components(separatedBy: "Audit catalog: START").count == 3)
        #expect(text.components(separatedBy: "Audit catalog: OUTCOME").count == 3)
    }
}

// MARK: - Prove at the mark (codex review 2026-10-16, F1–F5)

/// A row is marked gone only on evidence read AT THE MOMENT OF MARKING, on
/// the filesystem the file was expected on. Every test here runs the real
/// job (or the real apply) against the real filesystem; the only seam used
/// is the chunk's first-pass stat, and only to feed it a stale answer.
@MainActor
extension ShowAgainSandbox {
    /// A live row at an arbitrary path (the file may or may not be there).
    @discardableResult
    func row(at path: String, bytes: Int64 = 2_000) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = bytes
        model.records.append(r)
        return r
    }

    func link(_ name: String, to target: URL) throws -> URL {
        let link = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }
}

@Suite("Audit catalog — prove at the mark (codex 2026-10-16)", .serialized)
@MainActor
struct CatalogAuditProveAtTheMarkTests {

    // F1 — the filesystem the file was expected on, not the lexical root.

    @Test("F1: a path through a dangling symlink is 'could not check' (r2: a link in the path is not provable), never gone (the lexical root '/' is still mounted)")
    func danglingSymlinkParentIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_dangling"); defer { sb.cleanup() }
        let link = try sb.link("media", to: sb.root.appendingPathComponent("unplugged_drive"))
        let r = sb.row(at: link.appendingPathComponent("clip.mov").path)
        let job = await runAudit(sb.model)
        #expect(job.totals[.gone] == 0 && job.totals[.couldNotCheck] == 1, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "a file beyond a dangling link is not proven gone")
        #expect(job.problems.first { $0.path == r.fullPath }?.detail.contains("a link in the path") == true,
                Comment(rawValue: job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"))
        #expect(job.storedCount == 0)
    }

    @Test("F1: the symlink's target moved to another filesystem between the stat and the mark — never gone")
    func symlinkRetargetedToAnotherFilesystemIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_retarget"); defer { sb.cleanup() }
        // Planned through a link onto devfs (another filesystem than the sandbox).
        let link = try sb.link("drive", to: URL(fileURLWithPath: "/dev"))
        let r = sb.row(at: link.appendingPathComponent("clip.mov").path)
        let files = sb.files
        let job = await runAudit(sb.model) { j in
            let real = j.statPaths
            j.statPaths = { paths in
                let stats = real(paths)                                           // ENOENT on devfs
                try? FileManager.default.removeItem(at: link)                     // …then the link points elsewhere
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)
                return stats
            }
        }
        #expect(job.totals[.gone] == 0 && job.totals[.couldNotCheck] == 1, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "ENOENT on a different filesystem than the one planned is not proof")
        #expect(job.storedCount == 0)
    }

    // F2 — the mark is decided by a second, synchronous stat at the mark.

    @Test("F2: a file that is back at the mark is present, not marked (the chunk's ENOENT was transient)")
    func fileBackAtTheMarkIsPresentNotMarked() async throws {
        let sb = try ShowAgainSandbox.make("ca_transient"); defer { sb.cleanup() }
        let r = try sb.live("flicker.mov")
        let job = await runAudit(sb.model) { j in j.statPaths = { paths in paths.map { _ in .gone } } }
        #expect(job.totals[.present] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil && job.storedCount == 0, "present at the mark → not marked")
        #expect(r.auditSeenOn?.volumeUUID == sb.volumeUUID && job.stampedCount == 1, "the second look stamps where it found the file")
    }

    @Test("F2: an errno other than ENOENT/ENOTDIR at the mark is 'could not check', never gone")
    func errnoAtTheMarkIsCouldNotCheck() async throws {
        let sb = try ShowAgainSandbox.make("ca_eacces_mark"); defer { sb.cleanup() }
        let locked = sb.files.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let r = sb.row(at: locked.appendingPathComponent("clip.mov").path)
        try Data(repeating: 7, count: 2_000).write(to: URL(fileURLWithPath: r.fullPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let job = await runAudit(sb.model) { j in j.statPaths = { paths in paths.map { _ in .gone } } }
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil)
        #expect(job.problems.first { $0.path == r.fullPath }?.detail.contains("EACCES") == true,
                Comment(rawValue: job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"))
    }

    // F3 — the apply guard compares a snapshot of the fields that matter.

    @Test("F3: any planned field changed meanwhile — size, hash time, mtime, lifecycle, archive stage, archive fixity — drops the result as 'record changed'")
    func snapshotFieldsChangedMeanwhileDropTheResult() throws {
        let sb = try ShowAgainSandbox.make("ca_snapshot"); defer { sb.cleanup() }
        let rows = try (0..<7).map { try sb.live("snap\($0).mov", onDisk: false, seen: true) }
        let plan = sb.model.catalogAuditPlan()
        let items = try rows.map { r in try #require(plan.lanes.flatMap(\.items).first { $0.id == r.id }) }
        rows[0].sizeBytes = 9_999
        rows[1].contentHashAt = Date()
        rows[2].dateModified = "2026-10-16 12:00"
        rows[3].lifecycleStage = .reviewing
        rows[4].archiveStage = .readyForArchive
        rows[5].archiveFixity = ArchiveFixity(digest: "cd", verifiedAt: Date(), sizeBytes: 2_000)   // archived meanwhile
        rows[6].auditSeenOn = nil                                                                   // the stamp is in the key too (D5)
        for (r, it) in zip(rows, items) {
            let (apply, mark) = sb.model.applyCatalogAudit(.gone, to: it)
            #expect(apply.result == .recordChanged && mark == nil, "\(r.filename): \(apply.result)")
            #expect(r.removal == nil, "\(r.filename) was marked")
        }
    }

    @Test("F3: Trash → Put Back → Restore between plan and apply returns the marker to nil; the stale ENOENT must not mark the returned file")
    func trashPutBackRestoreMeanwhileIsNotMarked() throws {
        let sb = try ShowAgainSandbox.make("ca_putback"); defer { sb.cleanup() }
        let r = try sb.live("putback.mov")
        let plan = sb.model.catalogAuditPlan()
        let item = try #require(plan.lanes.flatMap(\.items).first { $0.id == r.id })
        let url = URL(fileURLWithPath: r.fullPath)
        let bytes = try Data(contentsOf: url)
        VideoScanModel.stampRemoval(r, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))   // another door: Trash
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)                                                                           // Finder: Put Back
        #expect(sb.model.clearRemoval(r) == nil)                                                           // Restore
        #expect(r.removal == nil)
        let (apply, mark) = sb.model.applyCatalogAudit(.gone, to: item)                                    // the stale answer
        #expect(apply.result == .present && mark == nil, "\(apply.result): \(apply.detail)")
        #expect(r.removal == nil, "a returned file was marked Missing")
    }

    // F4 — rollback by value, on the current instance, marker only.

    @Test("F4: rollback clears the mark on the CURRENT record instance (same id, path and marker), not a detached one")
    func rollbackClearsTheMarkOnTheCurrentInstance() async throws {
        let sb = try ShowAgainSandbox.make("ca_replace"); defer { sb.cleanup() }
        let original = try sb.live("swap.mov", onDisk: false, seen: true)
        var replacement: VideoRecord?
        let model = sb.model
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot) { j in
            j.chunkSize = 1; j.checkpointRows = 100
            j.saveCatalogForTesting = {
                // A reload / rescan replaced the object while the save was in flight.
                let twin = VideoRecord(id: original.id)
                twin.fullPath = original.fullPath; twin.filename = original.filename
                twin.directory = original.directory; twin.sizeBytes = original.sizeBytes
                if let marker = original.removal { VideoScanModel.stampRemoval(twin, marker) }
                if let i = model.records.firstIndex(where: { $0.id == original.id }) { model.records[i] = twin }
                replacement = twin
                return false
            }
        }
        #expect(job.saveFailed)
        let twin = try #require(replacement)
        #expect(model.record(forID: original.id) === twin)
        #expect(twin.removal == nil, "the current instance still carries the undone mark: \(String(describing: twin.removal))")
        #expect(sb.catalogLogText().contains("1 of 1 mark(s) undone"))
    }

    @Test("F4: a newer lifecycle / archive-stage edit survives the rollback; only the marker is put back")
    func rollbackLeavesANewerLifecycleEditAlone() async throws {
        let sb = try ShowAgainSandbox.make("ca_newer_edit"); defer { sb.cleanup() }
        let r = try sb.live("edited.mov", onDisk: false, seen: true)
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot) { j in
            j.chunkSize = 1; j.checkpointRows = 100
            j.saveCatalogForTesting = {
                r.lifecycleStage = .reviewing          // Triage moved it meanwhile
                r.archiveStage = .readyForArchive
                return false
            }
        }
        #expect(job.saveFailed)
        #expect(r.removal == nil, "the mark is undone")
        #expect(r.lifecycleStage == .reviewing && r.archiveStage == .readyForArchive,
                "the newer edit was overwritten: \(r.lifecycleStage) / \(r.archiveStage)")
    }

    @Test("F4: a newer marker from another door is left alone and the undo says so")
    func rollbackLeavesANewerMarkerAlone() async throws {
        let sb = try ShowAgainSandbox.make("ca_newer_marker"); defer { sb.cleanup() }
        let r = try sb.live("door.mov", onDisk: false, seen: true)
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot) { j in
            j.chunkSize = 1; j.checkpointRows = 100
            j.saveCatalogForTesting = {
                VideoScanModel.stampRemoval(r, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
                return false
            }
        }
        #expect(job.saveFailed)
        #expect(r.removal?.state == .inTrash, "the other door's marker stands")
        #expect(sb.catalogLogText().contains("0 of 1 mark(s) undone"))
    }

    // F5 — outcome precedence: failed > stopped > completed.

    @Test("F5: Stop followed by a save that is not acknowledged is FAILED (exit 1, run marker failed, row 'marks undone') — never 'stopped'")
    func stopThenUnacknowledgedSaveIsFailed() async throws {
        let sb = try ShowAgainSandbox.make("ca_stop_fail"); defer { sb.cleanup() }
        let rows = try (0..<5).map { try sb.live("sf\($0).mov", onDisk: false, seen: true) }
        let marker = CatalogAuditRunMarker()
        let job = CatalogAuditJob(model: sb.model, marker: marker)
        job.volumeOnline = { _ in true }
        job.laneRoot = sb.laneRoot
        job.tickMilliseconds = 20
        job.chunkSize = 1
        job.checkpointRows = 2
        job.saveCatalogForTesting = { [job] in
            job.cancel()            // Stop lands while the checkpoint save is in flight…
            return false            // …and the save is not acknowledged.
        }
        job.start()
        await job.task?.value
        if case .failed(let msg) = job.state {
            #expect(msg.hasPrefix("Failed — marks undone"), Comment(rawValue: msg))
        } else { Issue.record("expected failed, got \(job.state)") }
        #expect(CatalogAuditCLI.exitCode(for: job) == 1, "exit \(CatalogAuditCLI.exitCode(for: job))")
        #expect(marker.lastRun?.outcome == .failed && marker.lastRun?.partial == true)
        #expect(rows.allSatisfy { $0.removal == nil } && job.storedCount == 0, "every unsaved mark is undone")
        #expect(job.subtitle.hasPrefix("Failed — marks undone"), Comment(rawValue: job.subtitle))
        #expect(sb.catalogLogText().contains("OUTCOME failed (partial)"))
    }
}
