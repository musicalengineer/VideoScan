// ArchiveLockUpdateAndJobTests.swift
// Locked archive files (Rick 2026-09-27), the second half: Update… on a
// LOCKED file (unlock → one rename → relock; every outcome named), the
// Lock / Unlock archive files job (outcomes, poisoned manifest, 100k scale
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

// MARK: - Lock / Unlock archive files job

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

    private func run(_ model: VideoScanModel, _ mode: ArchiveLockJob.Mode,
                     seams: ArchiveFileLock.Seams = .live) async -> ArchiveLockJob {
        let job = ArchiveLockJob(mode: mode, model: model)
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
        let job = await run(a.model, .lock)
        #expect(job.totals.changed == 2 && job.totals.already == 1 && job.totals.failed == 1, "\(job.totals)")
        #expect(job.problems.map(\.relPath) == ["30_Video/Undated/xxxx-xx-xx_Gone.mov"])
        guard case .failed(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary == "Locked 2 · already locked 1 · failed 1")
        for rel in rels { #expect(MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel)") }
        // Folders never locked: a new file can still land beside them.
        try Data("new".utf8).write(to: a.url("30_Video/1990-1999/1991/new.mov"))
    }

    @Test("Unlock archive files… reverses it; a clean run finishes green with a one-line summary")
    func unlockReverses() async throws {
        let (a, rels) = try archive("job_unlock", files: 2)
        defer { a.sb.cleanup() }
        let locked = await run(a.model, .lock)
        guard case .finished(let s1) = locked.state else { Issue.record("\(locked.state)"); return }
        #expect(s1 == "Locked 2 · already locked 0 · failed 0")
        let unlocked = await run(a.model, .unlock)
        guard case .finished(let s2) = unlocked.state else { Issue.record("\(unlocked.state)"); return }
        #expect(s2 == "Unlocked 2 · already unlocked 0 · failed 0")
        for rel in rels { #expect(!MasterArchiveTestSupport.isLocked(a.url(rel).path)) }
    }

    @Test("isolation: a poisoned manifest (an escaping row) → the job refuses and NOTHING is flagged")
    func poisonedManifestRefuses() async throws {
        let (a, rels) = try archive("job_poison", files: 2)
        defer { a.sb.cleanup() }
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: "30_Video/../../../../etc/passwd", sha256: "00",
                                            sizeBytes: 1, originalPath: "/x", originalVolume: "t", recordID: UUID(),
                                            sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3),
                                      rootPath: a.root)
        let job = await run(a.model, .lock)
        guard case .failed(let why) = job.state else { Issue.record("\(job.state)"); return }
        #expect(job.wasRefused && why.contains("Refused"), "\(why)")
        for rel in rels { #expect(!MasterArchiveTestSupport.isLocked(a.url(rel).path), "\(rel) must not be flagged") }
    }

    @Test("isolation: the manifest replaced by a symlink → refused, nothing flagged")
    func symlinkManifestRefuses() async throws {
        let (a, rels) = try archive("job_symlink", files: 1)
        defer { a.sb.cleanup() }
        let real = a.sb.root.appendingPathComponent("elsewhere.csv")
        try FileManager.default.moveItem(at: a.sb.manifestURL, to: real)
        try FileManager.default.createSymbolicLink(at: a.sb.manifestURL, withDestinationURL: real)
        let job = await run(a.model, .lock)
        #expect(job.wasRefused)
        #expect(!MasterArchiveTestSupport.isLocked(a.url(rels[0]).path))
    }

    @Test("rows outside the media buckets are skipped and listed, never flagged")
    func nonMediaSkipped() {
        let root = "/tmp/test_lock_root"
        guard case .success(let plan) = ArchiveLockJob.plan(fromRelPaths: ["30_Video/a.mov", "40_Family_Tree/x.pdf",
                                                                           "00_Index/manifest.csv", "30_Video/a.mov"], root: root) else {
            Issue.record("plan refused"); return
        }
        #expect(plan.relPaths == ["30_Video/a.mov"])
        #expect(plan.skipped == ["40_Family_Tree/x.pdf", "00_Index/manifest.csv"])
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
        let job = await run(a.model, .lock, seams: stub)
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

    @Test("only Update… and Rick's Unlock job may clear the flag")
    func unlockReasons() {
        let allowed = ArchiveFileLock.Reason.allCases.filter(\.mayUnlock)
        #expect(Set(allowed) == [.updateUnlock, .unlockAll])
    }

    @Test(".unlock is requested only by ArchiveRefile.swift (Update) and ArchiveLockJob.swift (Rick's Unlock)")
    func unlockCallSites() throws {
        for (name, text) in try Self.sources() {
            let c = Self.code(text)
            if c.contains("set(.unlock") || c.contains("reason: .updateUnlock") || c.contains(".unlockAll") {
                #expect(["ArchiveRefile.swift", "ArchiveLockJob.swift", "ArchiveFileLock.swift", "ArchiveView.swift"].contains(name),
                        "\(name) asks to clear the lock")
            }
        }
    }
}
