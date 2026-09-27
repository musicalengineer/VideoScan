// ArchiveUpdateTests.swift
// Right-click ▸ Update… on an archived file (Rick's ruling 2026-09-27):
// LOGIC (name-only, date-only, both, known/estimated only, target exists,
// the 1884 guard as a target, rollback on an injected index failure, the
// DadThanksgiving1984-1 case end to end), PURE rules, the Promote guard end
// to end, and container names. Every test runs in a temp-dir sandbox archive
// (`test_*` fixtures) — never /Volumes/FamilyArchive, never the real
// catalog or ledger.

import Foundation
import Testing
@testable import VideoScan

@MainActor
enum UpdateFixture {

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
        func url(_ rel: String) -> URL { sb.archiveRoot.appendingPathComponent(rel) }
    }

    /// An archived file placed BY HAND at `relPath` with its manifest row and
    /// a promote-journal line — so a legacy "1884" placement (which Promote's
    /// guard now refuses) can be the starting point. Nothing uses Promote.
    static func make(_ label: String,
                     relPath: String = "30_Video/1880-1889/1884/1884-xx-xx_DadThanksgiving1984-1.mov",
                     recordDate: String = "1884-xx-xx", dateConfidence: String = "user-known",
                     copyUserDate: String? = "1884", copyConf: String? = "known") throws -> Archived {
        let sb = try MasterArchiveTestSupport.makeSandbox("upd_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let root = sb.archiveRoot.path
        let fileURL = sb.archiveRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: fileURL, bytes: 40_000, seed: 11)
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: fileURL.path))
        let srcPath = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_DadThanksgiving1984-1.mov"),
                                                             bytes: 40_000, seed: 11).path
        let source = MasterArchiveTestSupport.makeRecord(path: srcPath, userDate: "1884")
        let copy = MasterArchiveTestSupport.makeRecord(path: fileURL.path, userDate: copyUserDate)
        copy.userDateConfidence = copyConf
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = source.id
        copy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: Date(), sizeBytes: copy.sizeBytes)
        model.records = [source, copy]
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: relPath, sha256: sha,
                                            sizeBytes: copy.sizeBytes, originalPath: srcPath, originalVolume: "test",
                                            recordID: copy.id, sourceRecordID: source.id, recordDate: recordDate,
                                            dateConfidence: dateConfidence, people: [], starRating: 3), rootPath: root)
        try ArchivePromoteJournal.append(.init(sourceRecordID: source.id, sourcePath: srcPath, destRelPath: relPath,
                                               state: .done, sha256: sha, copyRecordID: copy.id, at: Date()), rootPath: root)
        return Archived(sb: sb, model: model, source: source, copy: copy, relPath: relPath, sha: sha)
    }

    static func preview(_ a: Archived) async throws -> ArchiveUpdatePreview {
        try #require(try? await a.model.makeArchiveUpdatePreview(recordID: a.source.id).get())
    }

    static func data(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    static func hint(_ y: Int, _ m: Int? = nil, _ d: Int? = nil) throws -> ArchiveDateHint {
        try #require(ArchiveRefile.hint(year: y, month: m, day: d))
    }
}

@Suite("Archive Update — logic", .serialized)
@MainActor
struct ArchiveUpdateLogicTests {

    @Test("DadThanksgiving1984-1 end to end: 1884 folder → 1980-1989/1984, name kept, one rename, manifest row + journal updated, record + ledger updated")
    func dadThanksgivingEndToEnd() async throws {
        let a = try UpdateFixture.make("dad")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        #expect(p.currentHint == .year(1884) && p.currentKnown && p.currentName == "DadThanksgiving1984-1")
        let h = try UpdateFixture.hint(1984)
        #expect(p.plan(name: p.currentName, hint: h, known: true).lines
                == ["Date: 1884 → 1984 (known)", "Folder: 1880-1889/1884 → 1980-1989/1984"])
        let inode = try FileManager.default.attributesOfItem(atPath: a.absPath)[.systemFileNumber] as? Int

        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true)
        #expect(r.kind == .updated, "\(r.message)")
        let to = "30_Video/1980-1989/1984/1984-xx-xx_DadThanksgiving1984-1.mov"
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: a.absPath))
        #expect(MasterArchiveTestSupport.sha256(ofFile: a.url(to).path) == a.sha)
        #expect(try fm.attributesOfItem(atPath: a.url(to).path)[.systemFileNumber] as? Int == inode, "a rename, never copy + delete")
        let row = try #require(MasterArchiveTestSupport.manifestRows(a.sb).first)
        #expect(row[1] == to && row[8] == "1984-xx-xx" && row[9] == "user-known")
        let journal = String(decoding: UpdateFixture.data(a.journalURL), as: UTF8.self)
        #expect(!journal.contains("1880-1889") && journal.contains("1984-xx-xx_DadThanksgiving1984-1"))
        #expect(a.copy.fullPath == a.url(to).path && a.copy.userDate == "1984" && a.copy.userDateConfidence == "known")
        #expect(a.source.userDate == "1884", "Update writes THIS archived record only — never the original")
        await a.model.mediaLedger.waitForPendingWrites()
        let ev = a.model.mediaLedger.events(forRecordID: a.copy.id).filter { $0.event == .archiveUpdated }
        #expect(ev.count == 1 && ev.first?.detail["from"] == a.relPath && ev.first?.detail["to"] == to)
        #expect(ev.first?.detail["reason"]?.contains("Date: 1884 → 1984 (known)") == true)
    }

    @Test("name only: same folder, new name, record_date unchanged")
    func nameOnly() async throws {
        let a = try UpdateFixture.make("name", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Thanksgivng.mov",
                                       recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        #expect(p.plan(name: "Thanksgiving", hint: p.currentHint, known: p.currentKnown).lines == ["Name: Thanksgivng → Thanksgiving"])
        let r = await a.model.updateArchivedFile(p, name: "Thanksgiving", hint: p.currentHint, known: p.currentKnown)
        #expect(r.kind == .updated, "\(r.message)")
        let to = "30_Video/1980-1989/1984/1984-xx-xx_Thanksgiving.mov"
        #expect(FileManager.default.fileExists(atPath: a.url(to).path))
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[1] == to)
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[8] == "1984-xx-xx")
    }

    @Test("date only: the folder follows the date")
    func dateOnly() async throws {
        let a = try UpdateFixture.make("date", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1991, 7)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: false)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.url("30_Video/1990-1999/1991/1991-07-xx_Clip.mov").path))
        #expect(a.copy.userDate == "1991-07" && a.copy.userDateConfidence == "estimated")
    }

    @Test("name and date at once: ONE move")
    func both() async throws {
        let a = try UpdateFixture.make("both")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984, 11, 22)
        #expect(p.plan(name: "Thanksgiving at Ma's", hint: h, known: true).lines.count == 3)
        let r = await a.model.updateArchivedFile(p, name: "Thanksgiving at Ma's", hint: h, known: true)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(MasterArchiveTestSupport.archivedFiles(a.sb) == ["30_Video/1980-1989/1984/1984-11-22_Thanksgiving-at-Ma-s.mov"])
    }

    @Test("known/estimated only: the file does not move; the manifest row's date_confidence and the record follow")
    func confidenceOnly() async throws {
        let a = try UpdateFixture.make("conf", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: p.currentHint, known: false)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[9] == "user-estimated")
        #expect(a.copy.userDateConfidence == "estimated")
    }

    @Test("nothing changed → refused, nothing touched")
    func nothingChanged() async throws {
        let a = try UpdateFixture.make("noop")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: p.currentHint, known: p.currentKnown)
        #expect(r.kind == .refused)
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("target exists → refused; nothing moved, manifest byte-identical")
    func targetExists() async throws {
        let a = try UpdateFixture.make("exists")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984)
        let blocker = a.url(p.plan(name: p.currentName, hint: h, known: true).toRelPath)
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not me".utf8).write(to: blocker)
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true)
        #expect(r.kind == .refused && r.message.contains("already exists"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(String(decoding: UpdateFixture.data(blocker), as: UTF8.self) == "not me")
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("the filing-year guard refuses 1884 (and after next year) as a TARGET")
    func guardAsTarget() async throws {
        let a = try UpdateFixture.make("guard", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        for y in [1884, ArchivePathResolver.latestFilingYear(now: Date()) + 1] {
            let h = try UpdateFixture.hint(y)
            #expect(p.guardRefusal(hint: h) != nil)
            let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true)
            #expect(r.kind == .refused, "\(y): \(r.message)")
        }
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
    }

    @Test("an injected index failure rolls back: file back, manifest + journal byte-identical, ledger 'archiveUpdateRolledBack'")
    func rollbackOnIndexFailure() async throws {
        let a = try UpdateFixture.make("rollback")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL), journal = UpdateFixture.data(a.journalURL)
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { _, _ in throw CocoaError(.fileWriteUnknown) }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest && UpdateFixture.data(a.journalURL) == journal)
        #expect(a.copy.fullPath == a.absPath && a.copy.userDate == "1884")
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(a.model.mediaLedger.events(forRecordID: a.copy.id).contains { $0.event == .archiveUpdateRolledBack })
    }

    @Test("catalog save fails after the archive moved → updatedWithWarnings, said plainly; the archive is the truth")
    func catalogSaveFailsIsReported() async throws {
        let a = try UpdateFixture.make("warn")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        var persistence = ArchiveRefilePersistence.live
        persistence.saveCatalog = { _ in false }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true,
                                                 persistence: persistence)
        #expect(r.kind == .updatedWithWarnings, "\(r.message)")
        #expect(r.message.contains("the catalog will pick up the new path on the next scan"))
        #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[1].hasPrefix("30_Video/1980-1989/1984/") == true)
    }

    @Test("read-only volume and a source digest mismatch are refused before anything moves")
    func refusalsBeforeMutation() async throws {
        let a = try UpdateFixture.make("refuse")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984)
        var ro = ArchiveRefileEngine.Seams.live
        ro.isVolumeReadOnly = { _ in true }
        #expect(await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true, seams: ro).kind == .refused)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: a.absPath))
        try fh.seek(toOffset: 100); fh.write(Data([1, 2, 3])); try fh.close()
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true)
        #expect(r.kind == .refused && r.message.contains("does not match its manifest fingerprint"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
    }

    @Test("Update works the same for mov / mp4 / mkv names", arguments: ["mov", "mp4", "mkv"])
    func containerNames(ext: String) async throws {
        let a = try UpdateFixture.make("mx_\(ext)", relPath: "30_Video/1880-1889/1884/1884-xx-xx_test_clip.\(ext)")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(MasterArchiveTestSupport.archivedFiles(a.sb) == ["30_Video/1980-1989/1984/1984-xx-xx_test_clip.\(ext)"])
    }
}

// MARK: - "Update changes ONLY what the sheet lists" (review r2 #4–#6)

/// A file shape the invariant is checked on.
struct UpdateShape: Sendable, CustomStringConvertible {
    let label: String, relPath: String, recordDate: String, dateConfidence: String
    let copyUserDate: String?, copyConf: String?
    var description: String { label }
}

private let longStem = String(repeating: "a", count: 80) + "_02"
private let updateShapes: [UpdateShape] = [
    .init(label: "legacy 1884", relPath: "30_Video/1880-1889/1884/1884-xx-xx_DadThanksgiving1984-1.mov",
          recordDate: "1884-xx-xx", dateConfidence: "user-known", copyUserDate: "1884", copyConf: "known"),
    .init(label: "catalog-renamed, no prefix", relPath: "30_Video/1980-1989/1984/Clip.mov",
          recordDate: "1984-xx-xx", dateConfidence: "user-known", copyUserDate: "1984", copyConf: "known"),
    .init(label: "undated", relPath: "30_Video/Undated/xxxx-xx-xx_Clip.mov",
          recordDate: "", dateConfidence: "", copyUserDate: nil, copyConf: nil),
    .init(label: "decade only", relPath: "30_Video/1980-1989/xxxx-xx-xx_Clip.mov",
          recordDate: "1980s", dateConfidence: "", copyUserDate: nil, copyConf: nil),
    .init(label: "inferred confidence, no user date", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Clip.mov",
          recordDate: "1984-xx-xx", dateConfidence: "inferred 0.87", copyUserDate: nil, copyConf: nil),
    .init(label: "80-char slug + collision suffix", relPath: "30_Video/1980-1989/1984/1984-xx-xx_\(longStem).mov",
          recordDate: "1984-xx-xx", dateConfidence: "user-known", copyUserDate: "1984", copyConf: "known"),
]

@Suite("Archive Update — changes ONLY what the sheet lists", .serialized)
@MainActor
struct ArchiveUpdateOnlyWhatIsListedTests {

    @Test("every combination of name / date / known-estimated: the sheet's list == what actually changed", arguments: updateShapes)
    func listEqualsChanges(shape: UpdateShape) async throws {
        for combo in 1..<8 {
            let changeName = combo & 1 != 0, changeDate = combo & 2 != 0, changeConf = combo & 4 != 0
            let a = try UpdateFixture.make("inv", relPath: shape.relPath, recordDate: shape.recordDate,
                                           dateConfidence: shape.dateConfidence,
                                           copyUserDate: shape.copyUserDate, copyConf: shape.copyConf)
            defer { a.sb.cleanup() }
            let p = try await UpdateFixture.preview(a)
            let name = changeName ? "New Name" : p.currentName
            let hint = changeDate ? try UpdateFixture.hint(1991) : p.currentHint
            let known = changeConf ? !p.currentKnown : p.currentKnown
            let plan = p.plan(name: name, hint: hint, known: known)
            let what = "\(shape.label) name=\(changeName) date=\(changeDate) conf=\(changeConf)"
            let rowBefore = try #require(MasterArchiveTestSupport.manifestRows(a.sb).first)
            let (dateBefore, confBefore) = (a.copy.userDate, a.copy.userDateConfidence)
            let inode = try FileManager.default.attributesOfItem(atPath: a.absPath)[.systemFileNumber] as? Int

            let r = await a.model.updateArchivedFile(p, name: name, hint: hint, known: known)
            #expect(r.kind == .updated, "\(what): \(r.message)")
            let row = try #require(MasterArchiveTestSupport.manifestRows(a.sb).first)
            let listed = { (k: String) in plan.lines.contains { $0.hasPrefix(k) } }
            // Name listed ⇔ the name part changed.
            #expect(listed("Name:") == (ArchiveRefile.currentName(ofFilename: (row[1] as NSString).lastPathComponent)
                                        != ArchiveRefile.currentName(ofFilename: (a.relPath as NSString).lastPathComponent)), "\(what)")
            // Folder listed ⇔ the folder changed.
            #expect(listed("Folder:") == ((row[1] as NSString).deletingLastPathComponent
                                          != (a.relPath as NSString).deletingLastPathComponent), "\(what)")
            // Date listed ⇔ the date provenance changed — nowhere otherwise.
            let dateMoved = row[8] != rowBefore[8] || row[9] != rowBefore[9]
                || a.copy.userDate != dateBefore || a.copy.userDateConfidence != confBefore
            #expect(listed("Date:") == dateMoved, "\(what): row \(rowBefore[8])/\(rowBefore[9]) → \(row[8])/\(row[9]), record \(dateBefore ?? "nil") → \(a.copy.userDate ?? "nil")")
            // No Name and no Folder line → the EXACT path, zero renames.
            if !listed("Name:") && !listed("Folder:") {
                #expect(row[1] == a.relPath, "\(what): path must not change")
                #expect(try FileManager.default.attributesOfItem(atPath: a.absPath)[.systemFileNumber] as? Int == inode)
            }
            #expect(row[1] == plan.toRelPath, "\(what): executed == shown")
        }
    }

    @Test("undated and decade-only files: a blank year keeps the current date, and a name-only update is allowed")
    func blankYearKeepsCurrentDate() async throws {
        for (rel, date) in [("30_Video/Undated/xxxx-xx-xx_Clip.mov", ""), ("30_Video/1980-1989/xxxx-xx-xx_Clip.mov", "1980s")] {
            let a = try UpdateFixture.make("blank", relPath: rel, recordDate: date, dateConfidence: "",
                                           copyUserDate: nil, copyConf: nil)
            defer { a.sb.cleanup() }
            let p = try await UpdateFixture.preview(a)
            let e = p.evaluate(name: "New Name", year: "", month: "", day: "", known: false)
            #expect(e.refusal == nil && e.hint == p.currentHint, "\(rel): \(e.refusal ?? "")")
            #expect(e.plan?.lines == ["Name: Clip → New-Name"], "\(rel): \(e.plan?.lines ?? [])")
            let r = await a.model.updateArchivedFile(p, name: "New Name", hint: p.currentHint, known: false)
            #expect(r.kind == .updated, "\(r.message)")
            #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[1]
                    == (rel as NSString).deletingLastPathComponent + "/xxxx-xx-xx_New-Name.mov")
            #expect(MasterArchiveTestSupport.manifestRows(a.sb).first?[8] == date)
        }
    }
}

@Suite("Archive Update — pure rules")
struct ArchiveUpdatePureTests {

    @Test("filing-year guard: video < 1900 or > next year refused; photos / documents / audio / undated never")
    func filingYearGuard() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 27
        let now = Calendar(identifier: .gregorian).date(from: c)!
        func f(_ hint: ArchiveDateHint, ext: String = "mov", stream: StreamType = .videoAndAudio) -> String? {
            ArchivePathResolver.filingYearRefusal(
                facts: .init(streamType: stream, filename: "test_x.\(ext)", ext: ext, dateHint: hint, dateIsLowConfidence: false),
                now: now)
        }
        #expect(f(.year(1884))?.contains("before 1900") == true)
        #expect(f(.decade(startYear: 1880)) != nil)
        #expect(f(.year(1900)) == nil && f(.year(1984)) == nil && f(.year(2027)) == nil)
        #expect(f(.year(2028))?.contains("after 2027") == true)
        #expect(f(.unknown) == nil)
        #expect(f(.year(1884), ext: "jpg") == nil && f(.year(1884), ext: "pdf") == nil)
        #expect(f(.year(1884), stream: .audioOnly) == nil)
    }

    @Test("currentName strips only the archive's own date prefix; manifest dates parse back")
    func namesAndDates() {
        #expect(ArchiveRefile.currentName(ofFilename: "1884-xx-xx_DadThanksgiving1984-1.mov") == "DadThanksgiving1984-1")
        #expect(ArchiveRefile.currentName(ofFilename: "Beach_1992.mov") == "Beach_1992")
        #expect(ArchiveRefile.hint(fromManifestDate: "1884-xx-xx") == .year(1884))
        #expect(ArchiveRefile.hint(fromManifestDate: "1984-11-xx") == .month(year: 1984, month: 11))
        #expect(ArchiveRefile.hint(fromManifestDate: "1984-11-22") == .day(year: 1984, month: 11, day: 22))
        #expect(ArchiveRefile.hint(fromManifestDate: "1940s") == .decade(startYear: 1940))
        #expect(ArchiveRefile.hint(fromManifestDate: "") == .unknown)
        #expect(ArchiveRefile.folder(ofRelPath: "30_Video/1880-1889/1884/a.mov") == "1880-1889/1884")
    }

    @Test("row-targeted manifest rewrite leaves every other byte alone")
    func manifestRewriteIsTargeted() throws {
        func row(_ rel: String, _ date: String) -> String {
            ArchiveManifestCSV.line(for: .init(promotedAt: Date(timeIntervalSince1970: 1_780_000_000), archiveRelPath: rel,
                                               sha256: "ab", sizeBytes: 1, originalPath: "/Volumes/X/\(rel)",
                                               originalVolume: "X", recordID: UUID(), sourceRecordID: UUID(),
                                               recordDate: date, dateConfidence: "user-known", people: ["Donna"], starRating: 3))
        }
        let target = "30_Video/1880-1889/1884/1884-xx-xx_a.mov"
        let text = MasterArchiveLayout.manifestHeader + "\n" + row(target + ".bak", "1884-xx-xx") + row(target, "1884-xx-xx")
        let out = try ArchiveRefile.rewriteManifestRows([UInt8](text.utf8), from: target,
                                                        to: "30_Video/1980-1989/1984/1984-xx-xx_a.mov",
                                                        recordDate: "1984-xx-xx", dateConfidence: "user-known")
        #expect(out.changedLines == 1)
        let before = text.split(separator: "\n", omittingEmptySubsequences: false)
        let after = String(decoding: out.bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(before[0] == after[0] && before[1] == after[1])
        let f = ArchiveManifestCSV.fields(ofLine: String(after[2]))
        #expect(f[1] == "30_Video/1980-1989/1984/1984-xx-xx_a.mov" && f[8] == "1984-xx-xx" && f[4] == "/Volumes/X/\(target)")
    }

    @Test("the grant refuses 00_Index, 40_Family_Tree and escapes")
    func grantRefusals() {
        let root = "/tmp/test_update_nowhere/Breen_Family_Archive"
        func denied(_ from: String, _ to: String) -> Bool {
            if case .failure = ArchiveRefileAuthorization.grant(rootPath: root, fromRelPath: from, toRelPath: to,
                                                                reason: "x", audit: { _ in }) { return true }
            return false
        }
        #expect(denied("00_Index/Archive_Inventory_Manifest.csv", "30_Video/1980-1989/1984/m.csv"))
        #expect(denied("40_Family_Tree/tree.ged", "30_Video/1980-1989/1984/t.ged"))
        #expect(denied("30_Video/1960-1969/1964/a.mov", "../outside/a.mov"))
        #expect(!denied("30_Video/1960-1969/1964/a.mov", "30_Video/1980-1989/1984/a.mov"))
    }
}

@Suite("Archive Update — Promote filing-year guard", .serialized)
@MainActor
struct ArchivePromoteFilingYearGuardTests {

    @Test("Promote refuses a video dated 1884 and one dated after next year: nothing copied, no manifest row")
    func promoteRefusesImplausibleYears() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("upd_pguard")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var recs: [VideoRecord] = []
        for (i, date) in ["1884", String(ArchivePathResolver.latestFilingYear(now: Date()) + 1)].enumerated() {
            let p = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_guard_\(i).mov"),
                                                           bytes: 10_000, seed: UInt64(i + 1)).path
            recs.append(MasterArchiveTestSupport.makeRecord(path: p, userDate: date))
        }
        model.records = recs
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: recs.map(\.id)))
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        let failed = job.outcomes.filter { $0.kind == .failed }
        #expect(failed.count == 2 && failed.contains { $0.detail.contains("before 1900") })
    }
}
