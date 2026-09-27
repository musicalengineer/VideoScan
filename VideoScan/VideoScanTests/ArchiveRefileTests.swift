// ArchiveRefileTests.swift
// Refile (Rick's approved workflow, 2026-09-27) — LOGIC, MEDIA-MATRIX names
// and ISOLATION. Every test runs against a temp-dir sandbox archive
// (`test_*` fixtures under the process temp dir): the real
// /Volumes/FamilyArchive, the App Support catalog and the real ledger are
// never touched (the model's catalog store and media ledger are pointed
// into the sandbox).
//
// The fixture: a file promoted with the date 1964 (the filing-year guard
// now refuses 1884 at Promote, so the legacy typo is simulated as "filed
// under 1964"), then re-dated 1984 on the original — Misfiled.

import Foundation
import Testing
@testable import VideoScan

@MainActor
enum RefileFixture {

    struct Archived {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord
        let copy: VideoRecord
        let relPath: String
        let sha: String
        var root: String { sb.archiveRoot.path }
        var absPath: String { sb.archiveRoot.appendingPathComponent(relPath).path }
        var journalURL: URL { sb.journalURL }
    }

    /// Promote `name` dated `filedAs`, then (optionally) re-date the
    /// original to `redate` — the Misfiled state.
    static func make(_ label: String, name: String = "test_DadThanksgiving-1.mov",
                     filedAs: String = "1964", redate: String? = "1984",
                     extraFiles: Int = 0) async throws -> Archived {
        let sb = try MasterArchiveTestSupport.makeSandbox("refile_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var recs: [VideoRecord] = []
        let path = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent(name),
                                                          bytes: 40_000, seed: 7).path
        let src = MasterArchiveTestSupport.makeRecord(path: path, userDate: filedAs)
        src.userDateConfidence = "known"
        recs.append(src)
        for i in 0..<extraFiles {
            let p = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_other_\(i).mp4"),
                                                           bytes: 20_000, seed: UInt64(100 + i)).path
            recs.append(MasterArchiveTestSupport.makeRecord(path: p, userDate: "1971"))
        }
        model.records = recs
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: recs.map(\.id)))
        guard case .finished = job.state else { throw FixtureError("promote did not finish: \(job.state)") }
        let copy = try #require(model.masterArchiveCopy(of: src))
        let rel = try #require(VerifyArchiveCopiesJob.relPath(of: copy.fullPath, underRoot: sb.archiveRoot.path))
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: copy.fullPath))
        if let redate {
            src.userDate = redate
            src.userDateConfidence = "known"
            model.noteUserDateEdited(src)   // the Inspector's hook: ledger dateSet + Misfiled refresh
            await model.mediaLedger.waitForPendingWrites()
        }
        await settle(model)
        return Archived(sb: sb, model: model, source: src, copy: copy, relPath: rel, sha: sha)
    }

    /// Wait for every queued Misfiled computation.
    static func settle(_ model: VideoScanModel) async {
        while let t = model.archiveMisfiledTask { await t.value }
    }

    static func data(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

@Suite("Archive Refile — logic", .serialized)
@MainActor
struct ArchiveRefileLogicTests {

    @Test("happy path: misfiled → refiled; one rename, fixity kept, manifest row + journal updated, record + ledger updated")
    func happyPath() async throws {
        let a = try await RefileFixture.make("happy", extraFiles: 2)
        defer { a.sb.cleanup() }
        #expect(a.relPath.hasPrefix("30_Video/1960-1969/1964/1964-xx-xx_test_DadThanksgiving-1"), "\(a.relPath)")

        // Misfiled list + the Catalog badge.
        let finding = try #require(a.model.archiveMisfiled.finding(forRecordID: a.source.id))
        #expect(finding.badgeText == "filed under 1964 · dated 1984")
        #expect(a.model.misfiledBadgeText(for: a.copy) == "filed under 1964 · dated 1984")
        #expect(a.model.archiveMisfiledRecords.map(\.id) == [a.source.id])

        let manifestBefore = String(decoding: RefileFixture.data(a.sb.manifestURL), as: UTF8.self)
        let otherLinesBefore = manifestBefore.split(separator: "\n").filter { !$0.contains(a.relPath) }
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: a.absPath)[.systemFileNumber] as? Int

        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        #expect(p.isMisfiled)
        #expect(p.initialHint == .year(1984))
        #expect(p.initialName == "test_DadThanksgiving-1")
        #expect(p.why.hasPrefix("You dated this 1984 (known) on "), "\(p.why)")
        #expect(p.why.contains("; it was filed on "), "\(p.why)")
        #expect(p.why.hasSuffix(" as 1964."), "\(p.why)")
        let to = p.target(hint: p.initialHint, name: p.initialName)
        #expect(to == "30_Video/1980-1989/1984/1984-xx-xx_test_DadThanksgiving-1.mov")

        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .refiled, "\(r.message)")

        let fm = FileManager.default
        let newAbs = a.sb.archiveRoot.appendingPathComponent(to).path
        #expect(!fm.fileExists(atPath: a.absPath), "old path gone (moved, not copied)")
        #expect(fm.fileExists(atPath: newAbs))
        #expect(MasterArchiveTestSupport.sha256(ofFile: newAbs) == a.sha)
        let inodeAfter = try fm.attributesOfItem(atPath: newAbs)[.systemFileNumber] as? Int
        #expect(inodeBefore == inodeAfter, "same inode — a rename, never copy + delete")
        #expect(MasterArchiveTestSupport.archivedFiles(a.sb).count == 3, "no duplicate left behind")

        // Manifest: the row now says the new place + date; every other line byte-identical.
        let rows = MasterArchiveTestSupport.manifestRows(a.sb)
        let row = try #require(rows.first { $0[2] == a.sha })
        #expect(row[1] == to)
        #expect(row[8] == "1984-xx-xx")
        #expect(row[9] == "user-known")
        #expect(!rows.contains { $0[1] == a.relPath })
        let manifestAfter = String(decoding: RefileFixture.data(a.sb.manifestURL), as: UTF8.self)
        #expect(manifestAfter.split(separator: "\n").filter { !$0.contains(to) } == otherLinesBefore)
        // Journal: the exact old path value followed the file.
        let journal = String(decoding: RefileFixture.data(a.journalURL), as: UTF8.self)
        #expect(!journal.contains(a.relPath) && !journal.contains(a.relPath.replacingOccurrences(of: "/", with: "\\/")))
        #expect(journal.contains(to) || journal.contains(to.replacingOccurrences(of: "/", with: "\\/")))
        // A #204 backup with our complete marker.
        let backups = a.sb.archiveRoot.appendingPathComponent("00_Index/.rename_backups")
        let dirs = try fm.contentsOfDirectory(atPath: backups.path)
        #expect(dirs.contains { ArchiveIndexRename.readMarker(in: backups.appendingPathComponent($0))?.complete == true })

        // Catalog record + dates agree with the folder.
        #expect(a.copy.fullPath == newAbs)
        #expect(a.copy.filename == "1984-xx-xx_test_DadThanksgiving-1.mov")
        #expect(a.copy.userDate == "1984" && a.copy.userDateConfidence == "known")
        #expect(a.copy.archiveFixity?.digest == a.sha)
        #expect(a.copy.notes.contains("Refile "))

        // Ledger.
        await a.model.mediaLedger.waitForPendingWrites()
        let ev = a.model.mediaLedger.events(forRecordID: a.source.id).filter { $0.event == .refiled }
        #expect(ev.count == 1)
        #expect(ev.first?.by == .rick)
        #expect(ev.first?.detail["from"] == a.relPath)
        #expect(ev.first?.detail["to"] == to)
        #expect(ev.first?.detail["provenance"]?.contains("user date 1984 (known)") == true)
        #expect((ev.first?.detail["reason"] ?? "").hasPrefix("You dated this 1984"))

        // No longer misfiled.
        await RefileFixture.settle(a.model)
        #expect(a.model.archiveMisfiled.finding(forRecordID: a.source.id) == nil)
        #expect(a.model.archiveMisfiled.rowIDs.isEmpty)
    }

    @Test("target exists → refused; nothing moved, manifest byte-identical")
    func targetExistsRefused() async throws {
        let a = try await RefileFixture.make("exists")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let to = p.target(hint: p.initialHint, name: p.initialName)
        let blocker = a.sb.archiveRoot.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not me".utf8).write(to: blocker)
        let manifest = RefileFixture.data(a.sb.manifestURL)
        let journal = RefileFixture.data(a.journalURL)

        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .refused)
        #expect(r.message.contains("already exists"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(String(decoding: RefileFixture.data(blocker), as: UTF8.self) == "not me")
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
        #expect(RefileFixture.data(a.journalURL) == journal)
        #expect(a.copy.fullPath == a.absPath)
    }

    @Test("source digest ≠ manifest → refused before anything moves")
    func digestMismatchRefused() async throws {
        let a = try await RefileFixture.make("digest")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        // Damage the archived file (sandbox only).
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: a.absPath))
        try h.seek(toOffset: 100); h.write(Data([0xFF, 0x00, 0xFF])); try h.close()
        let manifest = RefileFixture.data(a.sb.manifestURL)

        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .refused)
        #expect(r.message.contains("does not match its manifest fingerprint"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(!FileManager.default.fileExists(atPath: a.sb.archiveRoot.appendingPathComponent(p.target(hint: p.initialHint, name: p.initialName)).path))
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("volume read-only → refused; nothing touched")
    func readOnlyRefused() async throws {
        let a = try await RefileFixture.make("ro")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let manifest = RefileFixture.data(a.sb.manifestURL)
        var seams = ArchiveRefileEngine.Seams.live
        seams.isVolumeReadOnly = { _ in true }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .refused)
        #expect(r.message.contains("read-only"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("failure injected at (c) verify → file back at source, manifest + journal byte-identical, ledger 'refile rolled back'")
    func failureAtVerifyRollsBack() async throws {
        let a = try await RefileFixture.make("failc")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let to = p.target(hint: p.initialHint, name: p.initialName)
        let manifest = RefileFixture.data(a.sb.manifestURL)
        let journal = RefileFixture.data(a.journalURL)
        var seams = ArchiveRefileEngine.Seams.live
        let from = a.relPath
        seams.hashFile = { root, rel in
            // The source hashes true; the moved file "reads back" wrong.
            rel == from ? try ArchivePromoteEngine.sha256(root: root, relativePath: rel) : String(repeating: "0", count: 64)
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(!FileManager.default.fileExists(atPath: a.sb.archiveRoot.appendingPathComponent(to).path))
        #expect(MasterArchiveTestSupport.sha256(ofFile: a.absPath) == a.sha)
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
        #expect(RefileFixture.data(a.journalURL) == journal)
        #expect(a.copy.fullPath == a.absPath)
        await a.model.mediaLedger.waitForPendingWrites()
        let ev = a.model.mediaLedger.events(forRecordID: a.source.id)
        #expect(ev.contains { $0.event == .refileRolledBack && $0.detail["from"] == from })
        #expect(!ev.contains { $0.event == .refiled })
    }

    @Test("failure injected at (d) index publish → file back at source, manifest + journal byte-identical, ledger 'refile rolled back'")
    func failureAtIndexRollsBack() async throws {
        let a = try await RefileFixture.make("faild")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let to = p.target(hint: p.initialHint, name: p.initialName)
        let manifest = RefileFixture.data(a.sb.manifestURL)
        let journal = RefileFixture.data(a.journalURL)
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { _, url in
            throw CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSFilePathErrorKey: url.path])
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(!FileManager.default.fileExists(atPath: a.sb.archiveRoot.appendingPathComponent(to).path))
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
        #expect(RefileFixture.data(a.journalURL) == journal)
        #expect(a.copy.fullPath == a.absPath)
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(a.model.mediaLedger.events(forRecordID: a.source.id).contains { $0.event == .refileRolledBack })
    }

    @Test("failure at (d) on the SECOND index file → the published manifest is restored byte-identical")
    func failureAtSecondIndexFileRestoresManifest() async throws {
        let a = try await RefileFixture.make("faild2")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let manifest = RefileFixture.data(a.sb.manifestURL)
        let journal = RefileFixture.data(a.journalURL)
        var seams = ArchiveRefileEngine.Seams.live
        // First call (manifest) publishes; the journal's publish fails; the
        // rollback's re-publish of the manifest original must go through.
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let c = Counter()
        seams.indexPublisher = { data, url in
            let n: Int = c.lock.withLock { c.n += 1; return c.n }
            if n == 2 { throw CocoaError(.fileWriteUnknown) }
            try ArchiveIndexRename.livePublish(data, to: url)
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
        #expect(RefileFixture.data(a.journalURL) == journal)
        #expect(FileManager.default.fileExists(atPath: a.absPath))
    }

    @Test("user edits the target year and name → filed by Promote's rule; both records' dates follow")
    func userEditsYearAndName() async throws {
        let a = try await RefileFixture.make("edit")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let hint = try #require(ArchiveRefile.hint(year: 1985, month: 11, day: nil))
        let to = p.target(hint: hint, name: "Thanksgiving at Ma's")
        #expect(to == "30_Video/1980-1989/1985/1985-11-xx_Thanksgiving-at-Ma-s.mov")
        let r = await a.model.refileArchiveCopy(p, hint: hint, name: "Thanksgiving at Ma's")
        #expect(r.kind == .refiled, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.sb.archiveRoot.appendingPathComponent(to).path))
        #expect(a.copy.userDate == "1985-11")
        #expect(a.source.userDate == "1985-11")
        let row = try #require(MasterArchiveTestSupport.manifestRows(a.sb).first { $0[1] == to })
        #expect(row[8] == "1985-11-xx")
        await RefileFixture.settle(a.model)
        #expect(a.model.archiveMisfiled.rowIDs.isEmpty, "stable: neither record's date disagrees with the new folder")
    }

    @Test("Refile guard: a year before 1900 or after next year is refused — nothing touched")
    func refileGuard() async throws {
        let a = try await RefileFixture.make("guard")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let manifest = RefileFixture.data(a.sb.manifestURL)
        for hint in [ArchiveDateHint.year(1884), .year(ArchivePathResolver.latestFilingYear(now: Date()) + 1)] {
            #expect(p.guardRefusal(hint: hint) != nil)
            let r = await a.model.refileArchiveCopy(p, hint: hint, name: p.initialName)
            #expect(r.kind == .refused, "\(hint): \(r.message)")
            #expect(FileManager.default.fileExists(atPath: a.absPath))
            #expect(RefileFixture.data(a.sb.manifestURL) == manifest)
        }
    }

    @Test("an engine grant that does not cover the move refuses before any I/O")
    func grantMustCoverTheMove() throws {
        var lines: [String] = []
        let root = "/tmp/test_refile_nowhere/Breen_Family_Archive"
        let grant = try ArchiveRefileAuthorization.grant(rootPath: root, fromRelPath: "30_Video/1960-1969/1964/a.mov",
                                                         toRelPath: "30_Video/1980-1989/1984/a.mov",
                                                         reason: "test", audit: { lines.append($0) }).get()
        let req = ArchiveRefileEngine.Request(rootPath: root, fromRelPath: "30_Video/1960-1969/1964/a.mov",
                                              toRelPath: "30_Video/1990-1999/1994/a.mov", filename: "a.mov",
                                              recordDate: "1994-xx-xx", dateConfidence: "user-known")
        let out = ArchiveRefileEngine.execute(req, authorization: grant, audit: { lines.append($0) })
        guard case .refused(let why) = out else { Issue.record("\(out)"); return }
        #expect(why.contains("does not cover"))
        #expect(lines.first?.contains("exception granted") == true)
    }

    @Test("grant refuses 00_Index, 40_Family_Tree, escapes and a same-place move")
    func grantRefusals() {
        let root = "/tmp/test_refile_nowhere/Breen_Family_Archive"
        func denied(_ from: String, _ to: String) -> Bool {
            if case .failure = ArchiveRefileAuthorization.grant(rootPath: root, fromRelPath: from, toRelPath: to,
                                                                reason: "x", audit: { _ in }) { return true }
            return false
        }
        #expect(denied("00_Index/Archive_Inventory_Manifest.csv", "30_Video/1980-1989/1984/m.csv"))
        #expect(denied("40_Family_Tree/tree.ged", "30_Video/1980-1989/1984/t.ged"))
        #expect(denied("30_Video/1960-1969/1964/a.mov", "../outside/a.mov"))
        #expect(denied("30_Video/1960-1969/1964/a.mov", "30_Video/1960-1969/1964/a.mov"))
        #expect(!denied("30_Video/1960-1969/1964/a.mov", "30_Video/1980-1989/1984/a.mov"))
    }
}

// MARK: - Pure pieces (Why line, guard, rule)

@Suite("Archive Refile — pure rules")
struct ArchiveRefilePureTests {

    private let utc = TimeZone(identifier: "UTC")!
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.date(from: c)!
    }

    @Test("the Why line reads exactly as Rick approved it")
    func whyLineText() {
        let s = ArchiveRefile.whyLine(provenance: .userDate(onCopy: false, known: true, canonical: "1984"),
                                      dated: .year(1984), datedOn: day(2026, 9, 25),
                                      filedTail: "1880-1889/1884", promotedAt: day(2026, 9, 1),
                                      isMisfiled: true, now: day(2026, 9, 27), timeZone: utc)
        #expect(s == "You dated this 1984 (known) on 25 Sep 2026; it was filed on 1 Sep as 1884.")
        let older = ArchiveRefile.whyLine(provenance: .userDate(onCopy: true, known: false, canonical: "1984-11"),
                                          dated: .month(year: 1984, month: 11), datedOn: nil,
                                          filedTail: "Undated", promotedAt: day(2025, 3, 2),
                                          isMisfiled: true, now: day(2026, 9, 27), timeZone: utc)
        #expect(older == "You dated the archive copy November 1984 (estimated); it was filed on 2 Mar 2025 as Undated.")
        let machine = ArchiveRefile.whyLine(provenance: .machine(source: .embedded, confidence: 0.95),
                                            dated: .day(year: 1999, month: 7, day: 4), datedOn: nil,
                                            filedTail: "1990-1999", promotedAt: nil, isMisfiled: true,
                                            now: day(2026, 9, 27), timeZone: utc)
        #expect(machine == "Its date now reads 4 Jul 1999, from the date written inside the file; it is filed as the 1990s.")
    }

    @Test("Promote guard: video < 1900 or > next year refused; photos / documents / undated never")
    func filingYearGuard() {
        let now = day(2026, 9, 27)
        func f(_ hint: ArchiveDateHint, ext: String = "mov", stream: StreamType = .videoAndAudio) -> String? {
            ArchivePathResolver.filingYearRefusal(
                facts: .init(streamType: stream, filename: "test_x.\(ext)", ext: ext, dateHint: hint, dateIsLowConfidence: false),
                now: now)
        }
        #expect(f(.year(1884))?.contains("before 1900") == true)
        #expect(f(.day(year: 1899, month: 12, day: 31)) != nil)
        #expect(f(.decade(startYear: 1880)) != nil)
        #expect(f(.year(1900)) == nil)
        #expect(f(.year(1984)) == nil)
        #expect(f(.year(2027)) == nil, "next year is allowed")
        #expect(f(.year(2028))?.contains("after 2027") == true)
        #expect(f(.unknown) == nil)
        #expect(f(.year(1884), ext: "jpg") == nil, "an 1880s photo scan is real")
        #expect(f(.year(1884), ext: "pdf") == nil, "an 1880s document is real")
        #expect(f(.year(1884), stream: .audioOnly) == nil, "audio is not in the video bucket")
    }

    @Test("Misfiled rule: user date first (original, then copy), then a confident machine date; low-confidence never")
    func misfiledRule() {
        func cand(orig: String? = nil, copy: String? = nil, embedded: Date? = nil,
                  inferred: Date? = nil, inferredConf: Float? = nil,
                  rel: String = "30_Video/1960-1969/1964/1964-xx-xx_test_a.mov") -> ArchiveRefile.Candidate {
            .init(rowID: UUID(), copyID: UUID(), copyRelPath: rel, streamTypeRaw: StreamType.videoAndAudio.rawValue,
                  copyFilename: (rel as NSString).lastPathComponent, ext: "mov", originalFilename: "test_a.mov",
                  originalUserDate: orig, originalUserDateConfidence: orig == nil ? nil : "known",
                  copyUserDate: copy, copyUserDateConfidence: copy == nil ? nil : "estimated",
                  embeddedCreationDate: embedded, originMake: embedded == nil ? nil : "Sony",
                  originModel: embedded == nil ? nil : "DCR-TRV900", originEncoder: nil,
                  inferredRecordDate: inferred, inferredDateConfidence: inferredConf, inferredDateRange: nil)
        }
        #expect(ArchiveRefile.evaluate(cand(orig: "1964", copy: "1964")) == nil)
        #expect(ArchiveRefile.evaluate(cand(orig: "1984", copy: "1964"))?.badgeText == "filed under 1964 · dated 1984")
        #expect(ArchiveRefile.evaluate(cand(orig: "1964", copy: "1985"))?.badgeText == "filed under 1964 · dated 1985")
        // A user date that agrees outranks a machine date that does not.
        #expect(ArchiveRefile.evaluate(cand(orig: "1964", embedded: day(1999, 1, 1))) == nil)
        // No user date: a camera stamp (≥ floor) counts…
        let m = ArchiveRefile.evaluate(cand(embedded: day(1999, 7, 4)))
        #expect(m?.expectedTail == "1990-1999/1999")
        // …a low-confidence inference does not.
        #expect(ArchiveRefile.evaluate(cand(inferred: day(1999, 7, 4), inferredConf: 0.4)) == nil)
        // Undated folder, now dated → misfiled.
        #expect(ArchiveRefile.evaluate(cand(orig: "1984", rel: "30_Video/Undated/xxxx-xx-xx_test_a.mov"))?.filedLabel == "Undated")
        // Outside a media bucket → never.
        #expect(ArchiveRefile.evaluate(cand(orig: "1984", rel: "40_Family_Tree/x/test_a.mov")) == nil)
    }

    @Test("currentName strips only the archive's own date prefix")
    func currentName() {
        #expect(ArchiveRefile.currentName(ofFilename: "1884-xx-xx_DadThanksgiving1984-1.mov") == "DadThanksgiving1984-1")
        #expect(ArchiveRefile.currentName(ofFilename: "1992-07-15_Beach.mp4") == "Beach")
        #expect(ArchiveRefile.currentName(ofFilename: "xxxx-xx-xx_Tape_02.mkv") == "Tape_02")
        #expect(ArchiveRefile.currentName(ofFilename: "Beach_1992.mov") == "Beach_1992")
    }

    @Test("row-targeted manifest rewrite leaves every other byte alone")
    func manifestRewriteIsTargeted() throws {
        let header = MasterArchiveLayout.manifestHeader
        func row(_ rel: String, _ date: String) -> String {
            ArchiveManifestCSV.line(for: .init(promotedAt: Date(timeIntervalSince1970: 1_780_000_000), archiveRelPath: rel,
                                               sha256: "ab", sizeBytes: 1, originalPath: "/Volumes/X/\(rel)",
                                               originalVolume: "X", recordID: UUID(), sourceRecordID: UUID(),
                                               recordDate: date, dateConfidence: "user-known", people: ["Donna"],
                                               starRating: 3))
        }
        let target = "30_Video/1960-1969/1964/1964-xx-xx_a.mov"
        let other = "30_Video/1960-1969/1964/1964-xx-xx_a.mov.bak"
        let text = header + "\n" + row(other, "1964-xx-xx") + row(target, "1964-xx-xx") + row("30_Video/1970-1979/1971/b.mov", "1971-xx-xx")
        let out = try ArchiveRefile.rewriteManifestRows([UInt8](text.utf8), from: target,
                                                        to: "30_Video/1980-1989/1984/1984-xx-xx_a.mov",
                                                        recordDate: "1984-xx-xx", dateConfidence: "user-known")
        #expect(out.changedLines == 1)
        let before = text.split(separator: "\n", omittingEmptySubsequences: false)
        let after = String(decoding: out.bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(before.count == after.count)
        #expect(before[0] == after[0] && before[1] == after[1] && before[3] == after[3] && before[4] == after[4])
        let f = ArchiveManifestCSV.fields(ofLine: String(after[2]))
        #expect(f[1] == "30_Video/1980-1989/1984/1984-xx-xx_a.mov" && f[8] == "1984-xx-xx")
        #expect(f[4] == "/Volumes/X/\(target)", "the source path cell is NOT an archive path — untouched")
    }
}

// MARK: - Promote guard end to end

@Suite("Archive Refile — Promote filing-year guard", .serialized)
@MainActor
struct ArchivePromoteFilingYearGuardTests {

    @Test("Promote refuses a video dated 1884 and one dated after next year: nothing copied, no manifest row, reason logged")
    func promoteRefusesImplausibleYears() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("refile_pguard")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let future = String(ArchivePathResolver.latestFilingYear(now: Date()) + 1)
        var recs: [VideoRecord] = []
        for (i, date) in ["1884", future].enumerated() {
            let p = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_guard_\(i).mov"),
                                                           bytes: 10_000, seed: UInt64(i + 1)).path
            recs.append(MasterArchiveTestSupport.makeRecord(path: p, userDate: date))
        }
        model.records = recs
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: recs.map(\.id)))
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        let failed = job.outcomes.filter { $0.kind == .failed }
        #expect(failed.count == 2)
        #expect(failed.contains { $0.detail.contains("before 1900") })
        #expect(failed.contains { $0.detail.contains("after ") })
        #expect(recs.allSatisfy { model.masterArchiveCopy(of: $0) == nil })
    }
}

// MARK: - Media matrix (names only — Refile never decodes)

@Suite("Archive Refile — container names", .serialized)
@MainActor
struct ArchiveRefileMediaNameTests {

    @Test("refile works the same for mov / mp4 / mkv names", arguments: ["mov", "mp4", "mkv"])
    func refileAcrossExtensions(ext: String) async throws {
        let a = try await RefileFixture.make("mx_\(ext)", name: "test_mx_clip.\(ext)")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let to = p.target(hint: p.initialHint, name: p.initialName)
        #expect(to == "30_Video/1980-1989/1984/1984-xx-xx_test_mx_clip.\(ext)")
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .refiled, "\(r.message)")
        #expect(MasterArchiveTestSupport.sha256(ofFile: a.sb.archiveRoot.appendingPathComponent(to).path) == a.sha)
    }
}

// MARK: - Isolation

@Suite("Archive Refile — isolation", .serialized)
@MainActor
struct ArchiveRefileIsolationTests {

    @Test("poisoned manifest → Misfiled empty + logged, no crash; Refile refuses")
    func poisonedManifest() async throws {
        let a = try await RefileFixture.make("poison")
        defer { a.sb.cleanup() }
        #expect(a.model.archiveMisfiled.count == 1)
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        try Data("garbage,not,a,manifest\n\u{0}\u{1}".utf8).write(to: a.sb.manifestURL)
        a.model.refreshArchiveMisfiled(reason: "test", force: true)
        await RefileFixture.settle(a.model)
        #expect(a.model.archiveMisfiled.rowIDs.isEmpty)
        #expect(a.model.archiveMisfiled.note?.contains("manifest") == true)
        try await Task.sleep(for: .milliseconds(400))   // the console flushes every 0.15 s
        #expect(a.model.dashboard.consoleLines.contains { $0.contains("the Misfiled list is empty") })
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .refused)
        #expect(FileManager.default.fileExists(atPath: a.absPath))
    }

    @Test("absent manifest → Misfiled empty + logged, no crash")
    func absentManifest() async throws {
        let a = try await RefileFixture.make("absent")
        defer { a.sb.cleanup() }
        try FileManager.default.removeItem(at: a.sb.manifestURL)
        a.model.refreshArchiveMisfiled(reason: "test", force: true)
        await RefileFixture.settle(a.model)
        #expect(a.model.archiveMisfiled.rowIDs.isEmpty)
        #expect(a.model.archiveMisfiled.note != nil)
    }

    @Test("no Master Archive designated → empty list, nothing read")
    func noDesignation() async {
        let model = VideoScanModel()
        model.refreshArchiveMisfiled(reason: "test", force: true)
        await RefileFixture.settle(model)
        #expect(model.archiveMisfiled.rowIDs.isEmpty)
        #expect(model.archiveMisfiled.version == nil)
    }
}
