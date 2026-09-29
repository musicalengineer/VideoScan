// ArchiveLockUpdateAndJobTests.swift
// Locked archive files (Rick 2026-09-27), the second half: Update… on a
// LOCKED file (unlock → one rename → relock; every outcome named), the
// one-time "Lock files already in the archive" job (outcomes, poisoned manifest, 100k scale
// off the main actor), Verify Copies' report-only "not locked", the Catalog
// rename refusal, and the SENSOR that inventories every flag change. Temp
// sandboxes only; every flag is cleared in teardown (Sandbox.cleanup).

import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func lockFixture(_ a: UpdateFixture.Archived) {
    _ = ArchiveFileLock.set(.lock, root: a.root, relPath: a.relPath, reason: .promote, audit: { _ in })
}

private func inode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
}

// MARK: - Update on a locked file

@Suite("Update… — locked archive files", .serialized)
@MainActor
struct ArchiveUpdateLockTests {

    @Test("updated + relocked: unlock → one rename → relock; same inode, flag set after, ledger locked=true")
    func updatedAndRelocked() async throws {
        let a = try UpdateFixture.make("lk_ok")
        defer { a.sb.cleanup() }
        lockFixture(a)
        #expect(MasterArchiveTestSupport.isLocked(a.absPath))
        let before = inode(a.absPath)
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true)
        #expect(r.kind == .updated, "\(r.message)")
        let to = a.url("30_Video/1980-1989/1984/1984-xx-xx_DadThanksgiving1984-1.mov").path
        #expect(!FileManager.default.fileExists(atPath: a.absPath))
        #expect(inode(to) == before, "a rename, never copy + delete")
        #expect(MasterArchiveTestSupport.isLocked(to), "relocked at the new place")
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(a.model.mediaLedger.events(forRecordID: a.copy.id).first { $0.event == .archiveUpdated }?.detail["locked"] == "true")
    }

    @Test("updated, NOT relocked: an injected relock failure → updatedWithWarnings 'NOT locked', file intact at the target")
    func updatedNotRelocked() async throws {
        let a = try UpdateFixture.make("lk_warn")
        defer { a.sb.cleanup() }
        lockFixture(a)
        var seams = ArchiveRefileEngine.Seams.live
        seams.fileLock = ArchiveFileLock.Seams(
            apply: { root, rel, change in change == .lock ? .failed("injected relock failure") : ArchiveFileLock.liveApply(root: root, relPath: rel, change: change) },
            isLocked: ArchiveFileLock.liveIsLocked)
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .updatedWithWarnings && r.message.contains("NOT locked"), "\(r.message)")
        let to = a.url("30_Video/1980-1989/1984/1984-xx-xx_DadThanksgiving1984-1.mov").path
        #expect(MasterArchiveTestSupport.sha256(ofFile: to) == a.sha, "never lost")
        #expect(!MasterArchiveTestSupport.isLocked(to))
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[1] == "30_Video/1980-1989/1984/1984-xx-xx_DadThanksgiving1984-1.mov")
    }

    @Test("refused: locked and cannot be unlocked — nothing moved, still locked, manifest byte-identical")
    func lockedAndCannotUnlock() async throws {
        let a = try UpdateFixture.make("lk_refuse")
        defer { a.sb.cleanup() }
        lockFixture(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        var seams = ArchiveRefileEngine.Seams.live
        seams.fileLock = ArchiveFileLock.Seams(
            apply: { root, rel, change in change == .unlock ? .failed("injected: cannot unlock") : ArchiveFileLock.liveApply(root: root, relPath: rel, change: change) },
            isLocked: ArchiveFileLock.liveIsLocked)
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .refused && r.message.contains("locked and could not be unlocked"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath) && MasterArchiveTestSupport.isLocked(a.absPath))
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("rolled back: the index publish fails after the move — the original is back at its place AND locked again")
    func rollbackRelocksOriginal() async throws {
        let a = try UpdateFixture.make("lk_rb")
        defer { a.sb.cleanup() }
        lockFixture(a)
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { _, _ in throw CocoaError(.fileWriteUnknown) }
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(MasterArchiveTestSupport.isLocked(a.absPath), "re-locked at the original")
    }

    @Test("rolled back + relock fails: the outcome SAYS the file is not locked")
    func rollbackRelockFailureIsSaid() async throws {
        let a = try UpdateFixture.make("lk_rb2")
        defer { a.sb.cleanup() }
        lockFixture(a)
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { _, _ in throw CocoaError(.fileWriteUnknown) }
        seams.fileLock = ArchiveFileLock.Seams(
            apply: { root, rel, change in change == .lock ? .failed("injected") : ArchiveFileLock.liveApply(root: root, relPath: rel, change: change) },
            isLocked: ArchiveFileLock.liveIsLocked)
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .rolledBack && r.message.contains("not locked"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
    }

    @Test("codex r1 #1: lock-all reaching the file MID-Update (after the move, before the index publish fails) cannot break the rollback")
    func lockAllCannotInterruptUpdateRollback() async throws {
        let a = try UpdateFixture.make("lk_race")
        defer { a.sb.cleanup() }
        lockFixture(a)
        let root = a.root
        let to = "30_Video/1980-1989/1984/1984-xx-xx_DadThanksgiving1984-1.mov"
        var seams = ArchiveRefileEngine.Seams.live
        // Inside Update's transaction: the file is moved and unlocked; a
        // lock-all pass reaches it now, then the index publish fails.
        seams.indexPublisher = { _, _ in
            _ = ArchiveLockJob.lockOne(root: root, relPath: to, seams: .live)
            throw CocoaError(.fileWriteUnknown)
        }
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.kind): \(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath), "the original is back")
        #expect(!FileManager.default.fileExists(atPath: a.url(to).path))
        #expect(MasterArchiveTestSupport.isLocked(a.absPath))
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[1] == a.relPath, "file and index agree")
    }

    @Test("index-only update (confidence) on a correctly filed locked file: no move, still locked")
    func indexOnlyKeepsLock() async throws {
        let a = try UpdateFixture.make("lk_idx", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        lockFixture(a)
        let before = inode(a.absPath)
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: p.currentHint, known: false)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(inode(a.absPath) == before && MasterArchiveTestSupport.isLocked(a.absPath))
    }

    @Test("Catalog rename of a LOCKED archive file is refused before anything is written ('use Update…')")
    func catalogRenameRefusesLocked() throws {
        let a = try UpdateFixture.make("lk_ren", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        lockFixture(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        #expect(throws: VideoScanModel.RenameError.self) { try a.model.renameRecord(a.copy, toBaseName: "1984-xx-xx_Renamed") }
        #expect(FileManager.default.fileExists(atPath: a.absPath) && MasterArchiveTestSupport.isLocked(a.absPath))
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
    }
}

// MARK: - The one-time lock catch-up job

@Suite("Lock archive files… — the job", .serialized)
@MainActor
struct ArchiveLockJobTests {

    /// An archive with `n` manifest-listed files (none locked).
    private func archive(_ label: String, files n: Int) throws -> (UpdateFixture.Archived, [String]) {
        let a = try UpdateFixture.make(label, relPath: "30_Video/1980-1989/1984/1984-xx-xx_A.mov", recordDate: "1984-xx-xx")
        var rels = [a.relPath]
        for i in 1..<max(1, n) {
            let rel = "30_Video/1990-1999/1991/1991-xx-xx_F\(i).mov"
            let url = a.url(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MasterArchiveTestSupport.writeBlob(at: url, bytes: 2_000, seed: UInt64(100 + i))
            try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: rel, sha256: "00", sizeBytes: 2_000,
                                                originalPath: "/Volumes/test_S/f\(i).mov", originalVolume: "test",
                                                recordID: UUID(), sourceRecordID: UUID(), recordDate: "1991-xx-xx",
                                                dateConfidence: "", people: [], starRating: 3), rootPath: a.root)
            rels.append(rel)
        }
        return (a, rels)
    }

    private func run(_ model: VideoScanModel, seams: ArchiveFileLock.Seams = .live) async -> ArchiveLockJob {
        let job = ArchiveLockJob(model: model)
        job.fileLock = seams
        job.start()
        await job.task?.value
        return job
    }

    @Test("locked N / already N / failed N (listed): 3 files, one already locked, one listed but missing")
    func outcomes() async throws {
        let (a, rels) = try archive("job_mix", files: 3)
        defer { a.sb.cleanup() }
        _ = ArchiveFileLock.set(.lock, root: a.root, relPath: rels[2], reason: .promote, audit: { _ in })
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: "30_Video/Undated/xxxx-xx-xx_Gone.mov", sha256: "00",
                                            sizeBytes: 1, originalPath: "/x", originalVolume: "t", recordID: UUID(),
                                            sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3),
                                      rootPath: a.root)
        let job = await run(a.model)
        #expect(job.totals.changed == 2 && job.totals.already == 1 && job.totals.failed == 1, "\(job.totals)")
        #expect(job.problems.map(\.relPath) == ["30_Video/Undated/xxxx-xx-xx_Gone.mov"])
        guard case .failed(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary == "Locked 2 · already locked 1 · failed 1")
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel)") }
        // Folders never locked: a new file can still land beside them.
        try Data("new".utf8).write(to: a.url("30_Video/1990-1999/1991/new.mov"))
    }

    @Test("one-time: a clean run finishes green with a one-line summary, writes the marker, and the menu item goes; a run with a failure does not")
    func cleanRunHidesTheMenuItem() async throws {
        let (a, rels) = try archive("job_once", files: 2)
        defer { a.sb.cleanup() }
        #expect(!a.model.archiveLockCatchUpDone)
        #expect(a.model.archiveLockCatchUpMarkerURL.path.hasPrefix(a.sb.root.path), "the marker lives beside the sandbox catalog, never real App Support")
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: "30_Video/Undated/xxxx-xx-xx_Gone.mov", sha256: "00",
                                            sizeBytes: 1, originalPath: "/x", originalVolume: "t", recordID: UUID(),
                                            sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3),
                                      rootPath: a.root)
        _ = await run(a.model)
        #expect(!a.model.archiveLockCatchUpDone, "a failed file means not complete — the item stays")
        try FileManager.default.createDirectory(at: a.url("30_Video/Undated"), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: a.url("30_Video/Undated/xxxx-xx-xx_Gone.mov"), bytes: 10, seed: 3)
        let job = await run(a.model)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary == "Locked 1 · already locked 2 · failed 0")
        #expect(a.model.archiveLockCatchUpDone)
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path)) }
    }

    @Test("isolation: a poisoned manifest (an escaping row) → the job refuses and NOTHING is flagged")
    func poisonedManifestRefuses() async throws {
        let (a, rels) = try archive("job_poison", files: 2)
        defer { a.sb.cleanup() }
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: "30_Video/../../../../etc/passwd", sha256: "00",
                                            sizeBytes: 1, originalPath: "/x", originalVolume: "t", recordID: UUID(),
                                            sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3),
                                      rootPath: a.root)
        let job = await run(a.model)
        guard case .failed(let why) = job.state else { Issue.record("\(job.state)"); return }
        #expect(job.wasRefused && why.contains("Refused"), "\(why)")
        for rel in rels { #expect(!MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel) must not be flagged") }
    }

    @Test("codex r1 #5 (Rick's ruling): a SHORT / malformed row is skipped and REPORTED; valid rows still locked; its path is never touched")
    func truncatedRowReportedValidRowsLocked() async throws {
        let (a, rels) = try archive("job_trunc", files: 2)
        defer { a.sb.cleanup() }
        // A truncated row naming a file OUTSIDE the archive root.
        let outside = a.sb.root.appendingPathComponent("outside.mov")
        try Data("not archive".utf8).write(to: outside)
        let fh = try FileHandle(forWritingTo: a.sb.manifestURL)
        try fh.seekToEnd(); fh.write(Data("2026-09-27T00:00:00Z,../../outside.mov,00\n".utf8)); try fh.close()
        let job = await run(a.model)
        #expect(!job.wasRefused)
        #expect(job.totals.skipped == 1 && job.totals.changed == 2, "\(job.totals)")
        #expect(job.problems.contains { $0.kind == .skipped && $0.detail.contains("not a whole manifest row") })
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path)) }
        #expect(!MasterArchiveTestSupport.isLocked(outside.path), "the malformed row's path is never touched")
    }

    @Test("isolation: the manifest replaced by a symlink → refused, nothing flagged")
    func symlinkManifestRefuses() async throws {
        let (a, rels) = try archive("job_symlink", files: 1)
        defer { a.sb.cleanup() }
        let real = a.sb.root.appendingPathComponent("elsewhere.csv")
        try FileManager.default.moveItem(at: a.sb.manifestURL, to: real)
        try FileManager.default.createSymbolicLink(at: a.sb.manifestURL, withDestinationURL: real)
        let job = await run(a.model)
        #expect(job.wasRefused)
        #expect(!MasterArchiveTestSupport.isLocked(a.url(rels[0]).path))
    }

    @Test("rows outside the media buckets are skipped and listed, never flagged; a WHOLE escaping row refuses the plan")
    func nonMediaSkipped() {
        let root = "/tmp/test_lock_root"
        func row(_ rel: String) -> String { "2026-09-27T00:00:00Z,\(rel),00,1,/x,t,\(UUID()),\(UUID()),,,,3" }
        let header = MasterArchiveLayout.manifestHeaderLegacy
        let text = ([header] + ["30_Video/a.mov", "40_Family_Tree/x.pdf", "00_Index/manifest.csv", "30_Video/a.mov"].map(row))
            .joined(separator: "\n") + "\n"
        guard case .success(let plan) = ArchiveLockJob.plan(manifestText: text, root: root) else {
            Issue.record("plan refused"); return
        }
        #expect(plan.relPaths == ["30_Video/a.mov"])
        #expect(plan.skipped.map(\.row) == ["40_Family_Tree/x.pdf", "00_Index/manifest.csv"])
        guard case .failure = ArchiveLockJob.plan(manifestText: text + row("30_Video/../../../etc/passwd") + "\n", root: root) else {
            Issue.record("an escaping whole row must refuse"); return
        }
    }

    @Test("codex r2 #3: CRLF-terminated rows are each planned (all-CRLF, and CRLF rows after an LF header); a later CRLF escaping row still refuses")
    func crlfManifestRowsAreAllPlanned() {
        let root = "/tmp/test_lock_root"
        func row(_ rel: String) -> String { "2026-09-27T00:00:00Z,\(rel),00,1,/x,t,\(UUID()),\(UUID()),,,,3" }
        let header = MasterArchiveLayout.manifestHeaderLegacy
        let rows = ["30_Video/a.mov", "30_Video/b.mov"].map(row)
        let allCRLF = ([header] + rows).joined(separator: "\r\n") + "\r\n"
        let lfHeader = header + "\n" + rows.joined(separator: "\r\n") + "\r\n"
        for (label, text) in [("all CRLF", allCRLF), ("LF header, CRLF rows", lfHeader)] {
            guard case .success(let plan) = ArchiveLockJob.plan(manifestText: text, root: root) else {
                Issue.record("\(label): plan refused"); continue
            }
            #expect(plan.relPaths == ["30_Video/a.mov", "30_Video/b.mov"], "\(label): planned \(plan.relPaths)")
            #expect(plan.skipped.isEmpty, "\(label): skipped \(plan.skipped.map(\.row))")
            let poisoned = text + row("30_Video/../../../etc/passwd") + "\r\n"
            guard case .failure = ArchiveLockJob.plan(manifestText: poisoned, root: root) else {
                Issue.record("\(label): a later CRLF escaping row must refuse the plan"); continue
            }
        }
    }

    @Test("codex r2 #3 (end to end): CRLF rows appended after the LF header are ALL locked before the one-time marker is written")
    func crlfRowsAfterAnLFHeaderAreAllLocked() async throws {
        let (a, rels) = try archive("job_crlf", files: 1)
        defer { a.sb.cleanup() }
        var added: [String] = []
        for i in 1...2 {
            let rel = "30_Video/1990-1999/1992/1992-xx-xx_CR\(i).mov"
            try FileManager.default.createDirectory(at: a.url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try MasterArchiveTestSupport.writeBlob(at: a.url(rel), bytes: 500, seed: UInt64(200 + i))
            added.append(rel)
        }
        let crlf = added.map { "2026-09-27T00:00:00Z,\($0),00,500,/x,t,\(UUID()),\(UUID()),,,,3\r\n" }.joined()
        let fh = try FileHandle(forWritingTo: a.sb.manifestURL)
        try fh.seekToEnd(); fh.write(Data(crlf.utf8)); try fh.close()
        let job = await run(a.model)
        #expect(!job.wasRefused, "\(job.state)")
        #expect(job.totals.total == 3 && job.totals.changed == 3, "\(job.totals)")
        for rel in rels + added {
            #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel) was never locked")
        }
        #expect(a.model.archiveLockCatchUpDone == added.allSatisfy { MasterArchiveTestSupport.isLocked(a.url($0).path) },
                "the one-time marker must never claim completion while a listed file is unlocked")
    }

    @Test("codex r2 #3 follow-up: a NON-EMPTY manifest that yields nothing to lock does not write the one-time marker (the item stays); a header-only manifest still completes")
    func nothingPlannedFromNonEmptyManifestKeepsTheItem() async throws {
        let (a, _) = try archive("job_empty_plan", files: 1)
        defer { a.sb.cleanup() }
        // Every data row unparseable: nothing can be planned, nothing locked.
        let body = MasterArchiveLayout.manifestHeaderLegacy + "\n"
            + "2026-09-27T00:00:00Z,30_Video/x.mov,00\n" + "garbage\n"
        try Data(body.utf8).write(to: a.sb.manifestURL)
        let job = await run(a.model)
        #expect(!job.wasRefused && job.totals.total == 0 && job.totals.skipped == 2, "\(job.totals)")
        #expect(!a.model.archiveLockCatchUpDone, "nothing was planned from a non-empty manifest — the one-time item must stay")
        guard case .failed(let why) = job.state else { Issue.record("expected not-complete, got \(job.state)"); return }
        #expect(why.contains("none could be planned"), "\(why)")
        // A header-only manifest (nothing promoted yet) is genuinely complete.
        try Data((MasterArchiveLayout.manifestHeaderLegacy + "\n").utf8).write(to: a.sb.manifestURL)
        let clean = await run(a.model)
        guard case .finished = clean.state else { Issue.record("\(clean.state)"); return }
        #expect(a.model.archiveLockCatchUpDone)
    }

    @Test("codex #14 P1: a PARTLY malformed manifest locks the valid rows and reports the bad one, but never writes the one-time marker; repaired, the rerun locks both and completes")
    func partialMalformedManifestKeepsCatchUpAvailable() async throws {
        let (a, rels) = try archive("job_partial_malformed", files: 1)
        defer { a.sb.cleanup() }
        // b.mov exists in the archive, unlocked, but its manifest row is truncated.
        let b = "30_Video/1990-1999/1993/1993-xx-xx_B.mov"
        try FileManager.default.createDirectory(at: a.url(b).deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: a.url(b), bytes: 500, seed: 301)
        let good = try String(contentsOf: a.sb.manifestURL, encoding: .utf8)
        try Data((good + "2026-09-28T00:00:00Z,\(b),00\n").utf8).write(to: a.sb.manifestURL)

        let first = await run(a.model)
        #expect(!first.wasRefused, "\(first.state)")
        #expect(first.totals.changed == 1 && first.totals.skipped == 1, "\(first.totals)")
        #expect(first.problems.contains { $0.kind == .skipped && $0.detail.contains("not a whole manifest row") })
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel)") }
        #expect(!MasterArchiveTestSupport.isLocked(a.url(b).path), "the malformed row's file is never touched")
        #expect(!a.model.archiveLockCatchUpDone,
                "an unresolved malformed row means a listed file may be unlocked — the one-time item must stay")
        guard case .failed(let why) = first.state else { Issue.record("expected not-complete, got \(first.state)"); return }
        #expect(why.contains("could not be read"), "\(why)")

        // Rick repairs the row; the rerun locks b.mov and only then completes.
        let repaired = good + "2026-09-28T00:00:00Z,\(b),00,500,/x,t,\(UUID()),\(UUID()),,,,3\n"
        try Data(repaired.utf8).write(to: a.sb.manifestURL)
        let second = await run(a.model)
        guard case .finished = second.state else { Issue.record("\(second.state)"); return }
        for rel in rels + [b] { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel)") }
        #expect(a.model.archiveLockCatchUpDone)
    }

    @Test("codex #14 P1 boundary: intentional exclusions (non-media rows, duplicate rows) do NOT hold back completion")
    func nonMediaAndDuplicateRowsStillComplete() async throws {
        let (a, rels) = try archive("job_exclusions", files: 1)
        defer { a.sb.cleanup() }
        let good = try String(contentsOf: a.sb.manifestURL, encoding: .utf8)
        let dataLines = good.split(separator: "\n").dropFirst()
        let duplicate = dataLines.first.map { String($0) + "\n" } ?? ""
        let nonMedia = "2026-09-28T00:00:00Z,40_Family_Tree/tree.ged,00,1,/x,t,\(UUID()),\(UUID()),,,,3\n"
        try Data((good + duplicate + nonMedia).utf8).write(to: a.sb.manifestURL)
        let job = await run(a.model)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(job.totals.skipped == 1, "the non-media row is listed: \(job.totals)")
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path)) }
        #expect(a.model.archiveLockCatchUpDone)
    }

    @Test("scale: 100k manifest rows, stub flag setter, OFF the main actor, within a load-aware budget")
    func scale100k() async throws {
        let a = try UpdateFixture.make("job_scale", relPath: "30_Video/1980-1989/1984/1984-xx-xx_A.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        // 100k rows appended in one write (the manifest is plain CSV).
        var text = ""
        text.reserveCapacity(100_000 * 200)
        for i in 0..<99_999 {
            text += "2026-09-27T00:00:00Z,30_Video/1990-1999/1991/1991-xx-xx_S\(i).mov,00,1,/x,t,\(UUID().uuidString),\(UUID().uuidString),1991-xx-xx,,,3\n"
        }
        let fh = try FileHandle(forWritingTo: a.sb.manifestURL)
        try fh.seekToEnd(); fh.write(Data(text.utf8)); try fh.close()
        let counter = LockCounter()
        let stub = ArchiveFileLock.Seams(apply: { _, _, _ in
            counter.note(onMain: Thread.isMainThread)
            return .changed
        }, isLocked: { _, _ in true })
        let clock = ContinuousClock()
        let started = clock.now
        let job = await run(a.model, seams: stub)
        let elapsed = clock.now - started
        #expect(job.totals.total == 100_000 && job.totals.changed == 100_000, "\(job.totals)")
        #expect(counter.calls == 100_000 && counter.onMain == 0, "flag changes must run off the main actor (\(counter.onMain) on main)")
        #expect(job.sample.count == ArchiveLockJob.sampleCap, "successes kept are capped")
        let budget = PerformanceLane.loadAwareDebugCeiling(.seconds(20))
        #expect(elapsed < budget, "100k lock pass took \(elapsed) (budget \(budget), \(PerformanceLane.loadDescription()))")
        #expect(!MasterArchiveTestSupport.isLocked(a.absPath), "the stub touched no real file")
    }
}

final class LockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var onMain = 0
    func note(onMain main: Bool) {
        lock.lock(); calls += 1; if main { onMain += 1 }; lock.unlock()
    }
}

// MARK: - Verify Copies: report only

@Suite("Verify Copies — reports archived files that are NOT locked", .serialized)
@MainActor
struct VerifyArchiveNotLockedTests {

    @Test("an unlocked archived file is REPORTED (counted, summary) — never changed, never red on its own")
    func reportsNotLocked() async throws {
        let a = try UpdateFixture.make("vfy_nl", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let job = VerifyArchiveCopiesJob(model: a.model)
        job.start()
        await job.task?.value
        #expect(job.tally.notLocked == 1)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("1 not locked"), "\(summary)")
        #expect(!MasterArchiveTestSupport.isLocked(a.absPath), "report only")
        // Locked → not reported.
        lockFixture(a)
        let again = VerifyArchiveCopiesJob(model: a.model)
        again.start()
        await again.task?.value
        #expect(again.tally.notLocked == 0)
    }
}

// MARK: - Sensor: every flag change is inventoried

@Suite("Archive lock — flag-change inventory sensor")
struct ArchiveFileLockSensorTests {

    private static let appDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VideoScan")

    private static func sources() throws -> [(name: String, text: String)] {
        let e = try #require(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    /// Code only — string literals and `//` comments stripped — so the
    /// inventory's reasons and the documentation may NAME the calls.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line).replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"",
                                                          options: .regularExpression)
                if let r = s.range(of: "//") { s = String(s[..<r.lowerBound]) }
                return s
            }
            .joined(separator: "\n")
    }

    @Test("fchflags / chflags / lchflags appear ONLY in ArchiveFileLock.swift; SF_IMMUTABLE (schg) and isUserImmutableKey writes nowhere")
    func flagWritesOnlyInThePrimitive() throws {
        for (name, text) in try Self.sources() {
            let c = Self.code(text)
            for call in ["fchflags(", "lchflags(", " chflags(", "(chflags("] where c.contains(call) {
                #expect(name == "ArchiveFileLock.swift", "\(name) calls \(call) — every flag change goes through ArchiveFileLock.set")
            }
            #expect(!c.contains("SF_IMMUTABLE"), "\(name) uses the SYSTEM flag (schg) — never")
            #expect(!c.contains("isUserImmutableKey"), "\(name) sets the flag through URL resource values — use ArchiveFileLock")
        }
    }

    @Test("every ArchiveFileLock.set( call lives in a file inventoried in ArchiveVolumeProtection.fileLockInventory, with a reason")
    func callersAreInventoried() throws {
        let inventory = Set(ArchiveVolumeProtection.fileLockInventory.map(\.file))
        #expect(ArchiveVolumeProtection.fileLockInventory.allSatisfy { !$0.reason.isEmpty })
        var callers = Set<String>()
        for (name, text) in try Self.sources() where Self.code(text).contains("ArchiveFileLock.set(") {
            callers.insert(name)
            #expect(inventory.contains(name), "\(name) changes the lock flag but is not in the inventory")
        }
        #expect(callers.isSubset(of: inventory))
        #expect(callers.contains("PromoteToArchiveJob+Steps.swift") && callers.contains("ArchiveRefile.swift")
                && callers.contains("ArchiveLockJob.swift"))
    }

    @Test("only Update… may clear the flag (no Unlock job — Rick 2026-09-27)")
    func unlockReasons() {
        #expect(ArchiveFileLock.Reason.allCases.filter(\.mayUnlock) == [.updateUnlock])
    }

    @Test(".unlock is requested only by ArchiveRefile.swift (Update)")
    func unlockCallSites() throws {
        for (name, text) in try Self.sources() {
            let c = Self.code(text)
            if c.contains("set(.unlock") || c.contains(".updateUnlock") {
                #expect(["ArchiveRefile.swift", "ArchiveFileLock.swift"].contains(name), "\(name) asks to clear the lock")
            }
        }
    }
}
