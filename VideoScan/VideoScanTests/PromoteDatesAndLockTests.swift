// PromoteDatesAndLockTests.swift
// "When I promote a file, use the date I already gave its copies; and once
// it's in the archive, nothing but Update… can change or delete it." (Rick
// 2026-09-27). This file: the lock PRIMITIVE (the flag really stops unlink /
// rename / write, proven in a temp dir), the copies-date RULES, GH #219 (one
// date in filename + manifest + record), and Promote's lock OUTCOMES.
// Every fixture lives in a temp sandbox (`test_*`) — never /Volumes/FamilyArchive;
// every flag set here is cleared in teardown (Sandbox.cleanup → unlockTree).

import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - The primitive

@Suite("Archive file lock — the flag itself", .serialized)
struct ArchiveFileLockPrimitiveTests {

    private func fixture(_ label: String) throws -> (root: URL, rel: String, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_lock_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let rel = "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov"
        let file = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("family footage".utf8).write(to: file)
        return (root, rel, file)
    }

    private func teardown(_ root: URL) {
        MasterArchiveTestSupport.unlockTree(root)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a locked file resists unlink, rename and write; unlocking restores them")
    func lockedFileResists() throws {
        let f = try fixture("resist")
        defer { teardown(f.root) }
        var lines: [String] = []
        #expect(ArchiveFileLock.set(.lock, root: f.root.path, relPath: f.rel, reason: .promote, audit: { lines.append($0) }) == .changed)
        #expect(MasterArchiveTestSupport.isLocked(f.file.path))
        #expect(ArchiveFileLock.liveIsLocked(root: f.root.path, relPath: f.rel) == true)
        #expect(lines.count == 1 && lines[0].contains("locked") && lines[0].contains("promote"))
        // The kernel refuses every change.
        #expect(unlink(f.file.path) != 0 && errno == EPERM)
        let moved = f.file.deletingLastPathComponent().appendingPathComponent("moved.mov").path
        #expect(rename(f.file.path, moved) != 0 && errno == EPERM)
        #expect(open(f.file.path, O_WRONLY | O_APPEND) == -1 && errno == EPERM)
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: f.file) }
        #expect(FileManager.default.fileExists(atPath: f.file.path))
        #expect(try Data(contentsOf: f.file) == Data("family footage".utf8))
        // Folders are NOT locked: Promote can still add files beside it.
        let sibling = f.file.deletingLastPathComponent().appendingPathComponent("1984-xx-xx_Other.mov")
        try Data("new".utf8).write(to: sibling)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        // Idempotent; only an allowed reason clears it.
        #expect(ArchiveFileLock.set(.lock, root: f.root.path, relPath: f.rel, reason: .lockAll, audit: { _ in }) == .alreadySo)
        #expect(ArchiveFileLock.set(.unlock, root: f.root.path, relPath: f.rel, reason: .updateUnlock, audit: { _ in }) == .changed)
        #expect(!MasterArchiveTestSupport.isLocked(f.file.path))
        #expect(unlink(f.file.path) == 0)
    }

    @Test("only Update… may CLEAR the flag", arguments: ArchiveFileLock.Reason.allCases)
    func onlyAllowedReasonsUnlock(reason: ArchiveFileLock.Reason) throws {
        let f = try fixture("reason")
        defer { teardown(f.root) }
        _ = ArchiveFileLock.set(.lock, root: f.root.path, relPath: f.rel, reason: .promote, audit: { _ in })
        let r = ArchiveFileLock.set(.unlock, root: f.root.path, relPath: f.rel, reason: reason, audit: { _ in })
        if reason == .updateUnlock {
            #expect(r == .changed)
            #expect(!MasterArchiveTestSupport.isLocked(f.file.path))
        } else {
            guard case .failed = r else { Issue.record("\(reason) cleared the lock: \(r)"); return }
            #expect(MasterArchiveTestSupport.isLocked(f.file.path), "\(reason) must not clear it")
        }
    }

    @Test("absent → .absent; a symlinked path or an escape is refused, nothing flagged")
    func containment() throws {
        let f = try fixture("contain")
        defer { teardown(f.root) }
        #expect(ArchiveFileLock.set(.lock, root: f.root.path, relPath: "30_Video/Undated/nothing.mov", reason: .promote, audit: { _ in }) == .absent)
        let outside = f.root.deletingLastPathComponent().appendingPathComponent("test_lock_outside_\(UUID().uuidString.prefix(6)).mov")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = f.root.appendingPathComponent("30_Video/1980-1989/1984/link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        guard case .failed = ArchiveFileLock.set(.lock, root: f.root.path, relPath: "30_Video/1980-1989/1984/link.mov", reason: .promote, audit: { _ in }) else {
            Issue.record("a symlink was followed"); return
        }
        guard case .failed = ArchiveFileLock.set(.lock, root: f.root.path, relPath: "../\(outside.lastPathComponent)", reason: .promote, audit: { _ in }) else {
            Issue.record("an escape was followed"); return
        }
        #expect(!MasterArchiveTestSupport.isLocked(outside.path))
    }
}

// MARK: - The copies-date rules (pure)

@Suite("Promote — the date Rick gave its copies (rules)")
@MainActor
struct PromoteCopiesDateRuleTests {

    private func d(_ date: String, known: Bool, _ name: String = "copy.dv") -> PromoteCopyDate {
        PromoteCopyDate(recordID: UUID(), filename: name, volume: "LaCie", date: date, known: known, via: .sameBytes)
    }

    @Test("one distinct known date → pre-selected, one line")
    func singleKnown() {
        let c = PromoteCopyDates.decide([d("1984", known: true), d("1984", known: false, "b.mov")])
        guard case .preselected(let p, let n) = c else { Issue.record("\(c)"); return }
        #expect(p.date == "1984" && p.known && n == 2)
        #expect(c.line == "dated 1984 (known) from 2 copies")
    }

    @Test("dates disagree → ask, every copy listed (known first)")
    func disagreement() {
        let c = PromoteCopyDates.decide([d("1985", known: false, "a"), d("1984", known: true, "b")])
        guard case .ask(let list) = c else { Issue.record("\(c)"); return }
        #expect(list.map(\.date) == ["1984", "1985"])
    }

    @Test("estimated only → ask, even when they agree")
    func estimatedOnly() {
        guard case .ask(let list) = PromoteCopyDates.decide([d("1984", known: false), d("1984", known: false)]) else {
            Issue.record("estimated-only must ask"); return
        }
        #expect(list.count == 2)
    }

    @Test("no copy dates → nothing to ask")
    func none() { #expect(PromoteCopyDates.decide([]) == .noCopyDates) }

    private func rec(_ name: String, userDate: String? = nil, known: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name; r.fullPath = "/Volumes/test_V/\(name)"; r.sizeBytes = 10
        r.userDate = userDate
        r.userDateConfidence = userDate == nil ? nil : (known ? "known" : "estimated")
        return r
    }

    private func footage(_ g: UUID, _ c: FootageConfidence) -> FootageMembership {
        FootageMembership(groupID: g, groupSize: 2, confidence: c, role: .copy, rank: 1, likelyOriginalID: g,
                          originalInCatalog: true, evidence: [], scannedAt: Date(), algorithmVersion: 1)
    }

    @Test("gather: same whole-file digest and footage ≥ likely lend Rick's dates; machine dates, 'possible' groups and a file's own date never trigger")
    func gatherRules() {
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 10, mtimeNs: 0, ctimeNs: 1)
        let target = rec("target.mov")
        target.contentFixity = ContentFixity(digest: String(repeating: "ab", count: 32), byteCount: 10, stamp: stamp)
        target.inferredRecordDate = Date(timeIntervalSince1970: 0)   // machine date: irrelevant
        target.inferredDateConfidence = 0.9
        let twin = rec("twin.dv", userDate: "1984", known: true)
        twin.contentFixity = ContentFixity(digest: String(repeating: "ab", count: 32), byteCount: 10, stamp: stamp)
        let g = UUID()
        target.footage = footage(g, .likely)
        let reencode = rec("reencode.mp4", userDate: "1985-06")
        reencode.footage = footage(g, .likely)
        let machineOnly = rec("machine.mov")
        machineOnly.footage = footage(g, .likely)
        machineOnly.embeddedCreationDate = Date()
        let all = [target, twin, reencode, machineOnly]
        let got = PromoteCopyDates.gather(for: [target], records: all)[target.id] ?? []
        #expect(Set(got.map(\.filename)) == ["twin.dv", "reencode.mp4"])
        #expect(got.first { $0.filename == "twin.dv" }?.via == .sameBytes)
        // A 'possible' group lends nothing.
        target.footage = footage(g, .possible)
        #expect((PromoteCopyDates.gather(for: [target], records: all)[target.id] ?? []).map(\.filename) == ["twin.dv"])
        // A file with its OWN user date is never asked about.
        target.userDate = "1990"
        #expect(PromoteCopyDates.gather(for: [target], records: all).isEmpty)
        // Machine-only copies: no prompt at all.
        let lone = rec("lone.mov"); let m2 = rec("m2.mov")
        let g2 = UUID(); lone.footage = footage(g2, .identical); m2.footage = footage(g2, .identical)
        m2.inferredRecordDate = Date(); m2.inferredDateConfidence = 0.99
        #expect(PromoteCopyDates.gather(for: [lone], records: [lone, m2]).isEmpty)
    }

    @Test("the sheet's answer → override + source: typed wins, then a chosen copy, declined = none")
    func sheetResolve() {
        let copy = d("1984-11", known: true, "Christmas.dv")
        #expect(PromoteSheetDates.resolve(entryHint: .unknown, typed: "1947", copy: copy, declined: false).source == .typed)
        let c = PromoteSheetDates.resolve(entryHint: .unknown, typed: nil, copy: copy, declined: false)
        #expect(c.hint == .month(year: 1984, month: 11) && c.source == .copy(filename: "Christmas.dv", known: true))
        let n = PromoteSheetDates.resolve(entryHint: .unknown, typed: "", copy: copy, declined: true)
        #expect(n.hint == nil && n.source == nil)
    }

    @Test("dateDecision: the chosen date is the ONE value; a machine proposal is never written as a user date; the filename is the last word")
    func decision() {
        let facts = ArchivePathResolver.RecordFacts(streamType: .videoAndAudio, filename: "a.mov", ext: "mov",
                                                    dateHint: .year(2004), dateIsLowConfidence: true)
        let typed = PromoteToArchiveJob.dateDecision(sourceFacts: facts, sourceLabel: "low 0.41", override: .year(1947),
                                                     source: .typed, relPath: "30_Video/1940-1949/1947/1947-xx-xx_a.mov")
        #expect(typed.hint == .year(1947) && typed.confidenceLabel == "user-estimated" && typed.recordUserDate == "1947"
                && !typed.recordKnown && typed.provenance == "typed at Promote")
        let machine = PromoteToArchiveJob.dateDecision(sourceFacts: facts, sourceLabel: "low 0.41", override: .year(2004),
                                                       source: nil, relPath: "30_Video/2000-2009/2004/2004-xx-xx_a.mov")
        #expect(machine.recordUserDate == nil && machine.confidenceLabel == "low 0.41")
        let copy = PromoteToArchiveJob.dateDecision(sourceFacts: facts, sourceLabel: "", override: .year(1984),
                                                    source: .copy(filename: "t.dv", known: true),
                                                    relPath: "30_Video/1980-1989/1984/1984-xx-xx_a.mov")
        #expect(copy.confidenceLabel == "user-known" && copy.recordKnown && copy.provenance == "from copy t.dv")
        // Placed by an earlier run under another date: the filename wins, nothing written.
        let followed = PromoteToArchiveJob.dateDecision(sourceFacts: facts, sourceLabel: "", override: .year(1984),
                                                        source: .typed, relPath: "30_Video/2000-2009/2004/2004-xx-xx_a.mov")
        #expect(followed.hint == .year(2004) && followed.followedFilename && followed.recordUserDate == nil)
        // A decade stays a decade (no user-date form for it).
        let decade = PromoteToArchiveJob.dateDecision(sourceFacts: facts, sourceLabel: "", override: .decade(startYear: 1940),
                                                      source: .typed, relPath: "30_Video/1940-1949/xxxx-xx-xx_a.mov")
        #expect(decade.hint == .decade(startYear: 1940) && decade.recordUserDate == nil && !decade.followedFilename)
    }
}

// MARK: - Promote end to end: one date, and the lock outcomes

@Suite("Promote — one date in filename, manifest and record (GH #219) + lock outcomes", .serialized)
@MainActor
struct PromoteDatesAndLockEndToEndTests {

    private func setup(_ label: String, inferred: Bool = true) throws
        -> (sb: MasterArchiveTestSupport.Sandbox, model: VideoScanModel, rec: VideoRecord) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_tape.mov"), bytes: 30_000, seed: 7)
        // A LOW-confidence machine date (2004) the resolver sets aside: the
        // shape of GH #219 — the typed date filed it, the manifest did not know.
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path,
                                                      inferredDate: inferred ? ISO8601DateFormatter().date(from: "2004-06-01T00:00:00Z") : nil,
                                                      inferredConfidence: inferred ? 0.3 : nil)
        model.records = [rec]
        return (sb, model, rec)
    }

    private func run(_ model: VideoScanModel, ids: [UUID],
                     edit: (inout ArchivePromotePlan) -> Void = { _ in },
                     lock: ArchiveFileLock.Seams = .live) async throws -> PromoteToArchiveJob {
        var plan = try #require(model.buildPromotePlan(recordIDs: ids))
        edit(&plan)
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.fileLock = lock
        job.start()
        await job.task?.value
        await job.completionTask?.value
        return job
    }

    @Test("GH #219: a date TYPED at Promote lands in the filename prefix, the manifest cells and the archived record — one value")
    func typedDateAgreesEverywhere() async throws {
        let (sb, model, rec) = try setup("gh219")
        defer { sb.cleanup() }
        let job = try await run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .year(1947)
            $0.archiveDateSources[rec.id] = .typed
        }
        #expect(job.outcomes.first?.kind == .promoted, "\(job.outcomes)")
        let files = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(files.count == 1 && files[0].hasPrefix("30_Video/1940-1949/1947/1947-xx-xx_"), "\(files)")
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row[8] == "1947-xx-xx" && row[9] == "user-estimated", "manifest \(row[8]) / \(row[9])")
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == "1947" && copy.userDateConfidence == "estimated")
        #expect(copy.notes.contains("typed at Promote"))
        #expect(rec.userDate == nil, "the SOURCE is never re-dated")
    }

    @Test("a date taken from a copy (known) → user-known everywhere, provenance 'from copy <name>'")
    func copyDateAgreesEverywhere() async throws {
        let (sb, model, rec) = try setup("copydate")
        defer { sb.cleanup() }
        let job = try await run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .month(year: 1984, month: 11)
            $0.archiveDateSources[rec.id] = .copy(filename: "Christmas84.dv", known: true)
        }
        #expect(job.outcomes.first?.kind == .promoted)
        #expect(MasterArchiveTestSupport.archivedFiles(sb).first?.hasPrefix("30_Video/1980-1989/1984/1984-11-xx_") == true)
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row[8] == "1984-11-xx" && row[9] == "user-known")
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == "1984-11" && copy.userDateConfidence == "known" && copy.notes.contains("from copy Christmas84.dv"))
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.events(forRecordID: copy.id).contains { $0.event == .dateSet && $0.detail["date"] == "1984-11" })
    }

    @Test("a machine override (no source) places the file but writes no user date")
    func machineOverrideNotWritten() async throws {
        let (sb, model, rec) = try setup("machine", inferred: false)
        defer { sb.cleanup() }
        _ = try await run(model, ids: [rec.id]) { $0.archiveDateOverrides[rec.id] = .year(1999) }
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == nil)
        #expect(MasterArchiveTestSupport.manifestRows(sb).first?[8] == "1999-xx-xx", "placement and the index still agree")
    }

    @Test("promoted + locked: the archived file carries the flag; ledger locked=true")
    func promotedAndLocked() async throws {
        let (sb, model, rec) = try setup("locked")
        defer { sb.cleanup() }
        let job = try await run(model, ids: [rec.id])
        let o = try #require(job.outcomes.first)
        #expect(o.kind == .promoted && o.notLocked == nil)
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        #expect(MasterArchiveTestSupport.isLocked(sb.archiveRoot.appendingPathComponent(rel).path))
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.events(forRecordID: rec.id).first { $0.event == .archived }?.detail["locked"] == "true")
    }

    @Test("promoted, NOT locked: an injected lock failure keeps the good copy, warns on the row, logs, ledger locked=false")
    func promotedNotLocked() async throws {
        let (sb, model, rec) = try setup("notlocked")
        defer { sb.cleanup() }
        let failing = ArchiveFileLock.Seams(apply: { _, _, _ in .failed("injected: EPERM") }, isLocked: { _, _ in false })
        let job = try await run(model, ids: [rec.id], lock: failing)
        let o = try #require(job.outcomes.first)
        #expect(o.kind == .promoted && o.notLocked == "injected: EPERM")
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("NOT locked"), "\(summary)")
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        #expect(!MasterArchiveTestSupport.isLocked(sb.archiveRoot.appendingPathComponent(rel).path))
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1, "never a rollback of a good copy")
        #expect(model.masterArchiveCopy(of: rec) != nil)
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.events(forRecordID: rec.id).first { $0.event == .archived }?.detail["locked"] == "false")
    }

    @Test("refused: the filing-year guard (1884) — nothing copied, nothing flagged")
    func refused() async throws {
        let (sb, model, rec) = try setup("refused")
        defer { sb.cleanup() }
        let job = try await run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .year(1884); $0.archiveDateSources[rec.id] = .typed
        }
        #expect(job.outcomes.first?.kind == .failed)
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && MasterArchiveTestSupport.manifestRows(sb).isEmpty)
    }

    @Test("rolled back: a durability barrier fails mid-copy — no file, no partial, nothing locked, no row")
    func rolledBack() async throws {
        let (sb, model, rec) = try setup("rollback")
        defer { sb.cleanup() }
        let box = BarrierBox()
        box.failFullFsync = true
        let job = try await ArchivePromoteEngine.$barriers.withValue(box.barriers) {
            try await run(model, ids: [rec.id])
        }
        #expect(job.outcomes.first?.kind == .failed)
        let everything = (try? FileManager.default.subpathsOfDirectory(atPath: sb.archiveRoot.path)) ?? []
        #expect(!everything.contains { $0.hasSuffix(".partial") })
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && MasterArchiveTestSupport.manifestRows(sb).isEmpty)
    }
}
