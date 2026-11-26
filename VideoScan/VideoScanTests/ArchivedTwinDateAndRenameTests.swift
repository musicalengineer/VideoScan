import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Codex #383 (round 2 on GH #221 / #477): archived means fixed, for every copy
//
// Rule 3 ("Archived means fixed"): only Update… changes an archived file's
// name or date. Two paths still went around it:
//
// P1-a  catalog.sqlite keeps Rick's date per CONTENT (user_dates is keyed by
//       the whole-file digest; the loader joins it by digest), and a commit
//       copies a date onto every in-memory copy of the same content. So a
//       date typed on an UNARCHIVED copy became the archived twin's date —
//       at once, and after every relaunch — while the archive's folder,
//       filename and manifest row stayed at the old date. Now: if any live
//       copy of the content is archived, the content's date is fixed — the
//       Inspector refuses for every copy and offers Update… on the archived
//       copy; the commit-time copy step declines to write a date onto an
//       archived copy (defence in depth, one log line).
// P1-b  Catalog Rename… refused only a LOCKED archive file. Promote can leave
//       an archive copy unlocked (a lock failure is recorded, the promotion
//       stands), and that copy could be renamed outside Update…. Now any
//       Master Archive file (a promoted copy or anything under the root) is
//       refused, locked or not.
//
// Dimensions:
//   logic      the twin of an archived copy is refused (save, clear, confidence
//              flip); a removed archived copy does not fix anything; a
//              different content is not a twin; the control is written
//   writer     through catalog.sqlite: refused inside the debounce window of a
//              notes edit, during a write hold, across a viewer flip — the
//              relaunch shows both copies at the filed date
//   defence    a date written on the twin by any other path is not copied onto
//              the archived copy in memory; one log line says so honestly
//   truth      the Inspector's words name the archived copy and ITS date
//   scale      100k records: the twin lookup within a Debug budget
//   rename     an UNLOCKED archive copy and a file under the root are refused;
//              file, record and index unchanged; a promoted source still renames
//   media:     not applicable — no media decoded.

@MainActor
@Suite("Codex #383 — an archived copy fixes its content's date; Rename never bypasses Update…", .serialized)
struct ArchivedTwinDateTests {

    typealias F = DossierAdmissionFixtures

    private static let digest = String(repeating: "ab", count: 32)

    /// Two copies of one content (same size, same whole-file SHA-256).
    private static func twins(_ sb: F.Sandbox, archivedStage: Bool = false) -> (original: VideoRecord, copy: VideoRecord) {
        let original = sb.record("test_twin_original.mov", stage: .cataloged, onDisk: false)
        let copy = sb.record("test_twin_copy.mov", stage: archivedStage ? .archived : .cataloged, onDisk: false)
        for r in [original, copy] {
            r.sizeBytes = 4_096
            r.contentFixity = Self.fixity(digest, 4_096)
            r.userDate = "1984"
            r.userDateConfidence = UserDateConfidence.known.rawValue
        }
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = original.id
        sb.model.records.append(contentsOf: [original, copy])
        return (original, copy)
    }

    private static func fixity(_ digest: String, _ size: Int64) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 0), computedAt: Date())
    }

    private static func fixed(_ sb: F.Sandbox, _ r: VideoRecord) -> VideoRecord? {
        InspectorDateEdit.archivedCopy(fixing: r, in: sb.model.records, isReadOnly: sb.model.isDateReadOnlyItself)
    }

    // MARK: Logic

    @Test("RED before #383: Save / Clear / confidence flip on the unarchived twin of an archived copy are refused")
    func twinIsRefused() throws {
        let sb = try F.Sandbox("twin_refused")
        defer { sb.cleanup() }
        let (original, copy) = Self.twins(sb)
        #expect(!sb.model.isDateReadOnlyItself(original), "the original itself is not archived")
        #expect(sb.model.isDateReadOnly(original), "GH #528: the seam itself now calls the twin read-only")
        let fixedBy = try #require(Self.fixed(sb, original), "the archived copy fixes the content's date")
        #expect(fixedBy === copy)
        #expect(InspectorDateEdit.save(entry: "1992", known: true, to: original, readOnly: true) == .refusedArchived)
        #expect(InspectorDateEdit.clear(original, readOnly: true) == .refusedArchived)
        #expect(InspectorDateEdit.save(entry: "1984", known: false, to: original, readOnly: true) == .refusedArchived)
        #expect(original.userDate == "1984" && copy.userDate == "1984")
        #expect(original.userDateConfidence == UserDateConfidence.known.rawValue)
    }

    @Test("a removed archived copy fixes nothing; another content is no twin; an archived record fixes itself")
    func whoFixesWhat() throws {
        let sb = try F.Sandbox("twin_who")
        defer { sb.cleanup() }
        let (original, copy) = Self.twins(sb)
        let other = sb.record("test_other.mov", stage: .cataloged, onDisk: false)
        other.sizeBytes = 4_096
        other.contentFixity = Self.fixity(String(repeating: "cd", count: 32), 4_096)
        let unhashed = sb.record("test_unhashed.mov", stage: .cataloged, onDisk: false)
        unhashed.sizeBytes = 4_096
        sb.model.records.append(contentsOf: [other, unhashed])
        #expect(Self.fixed(sb, other) == nil)
        #expect(Self.fixed(sb, unhashed) == nil, "no whole-file digest: its date is its own")
        #expect(Self.fixed(sb, copy) === copy)
        copy.removal = .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash)
        #expect(Self.fixed(sb, original) == nil, "a copy that is gone fixes nothing")
        #expect(InspectorDateEdit.save(entry: "1992", known: false, to: original,
                                       readOnly: Self.fixed(sb, original) != nil) == .saved("1992"))
    }

    @Test("TRUTH: the twin's words name the archived copy and the date IT was filed under")
    func twinWords() {
        let original = VideoRecord()
        original.userDate = "1992"
        let copy = VideoRecord()
        copy.filename = "1984-xx-xx_Trip.mov"
        copy.userDate = "1984"
        copy.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(InspectorDateView.archivedFiledText(original, fixedBy: copy)
                == "A copy of this file is in the archive (1984-xx-xx_Trip.mov). Filed as 1984 (you're sure). "
                + "Archived, so the date is fixed. Use Update… to change it.")
        #expect(InspectorDateView.archivedFiledText(copy, fixedBy: copy)
                == "Filed as 1984 (you're sure). Archived, so the date is fixed. Use Update… to change it.")
    }

    @Test("SCALE: the twin lookup over 100k records stays within budget")
    func scale() throws {
        let sb = try F.Sandbox("twin_scale")
        defer { sb.cleanup() }
        let (original, copy) = Self.twins(sb)
        var records: [VideoRecord] = []
        records.reserveCapacity(100_002)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.sizeBytes = Int64(10_000 + i % 5_000)
            r.contentFixity = Self.fixity(String(format: "%064x", i), r.sizeBytes)
            records.append(r)
        }
        records.append(original)
        records.append(copy)
        let clock = ContinuousClock()
        var found: VideoRecord?
        let elapsed = clock.measure {
            found = InspectorDateEdit.archivedCopy(fixing: original, in: records, isReadOnly: sb.model.isDateReadOnlyItself)
        }
        #expect(found === copy)
        let budget = PerformanceLane.debugCeiling(.milliseconds(100))
        print("[ArchivedTwinDateTests] twin lookup over 100k: \(elapsed)")
        #expect(elapsed < budget, "twin lookup took \(elapsed) (budget \(budget))")
    }

    // MARK: Writer (catalog.sqlite)

    private func relaunch(_ scene: CutoverScene) async throws -> VideoScanModel {
        if let committer = scene.model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    /// Original + archived copy of one content, both filed 1984, stored.
    private func storedTwins(_ scene: CutoverScene) throws -> (original: VideoRecord, copy: VideoRecord) {
        let original = try scene.record(.curatedConflictA)
        let copy = try scene.record(.curatedConflictB)
        try #require(CatalogCommit.digest(of: original) != nil && CatalogCommit.digest(of: original) == CatalogCommit.digest(of: copy),
                     "the fixture's two rows are copies of one content")
        original.userDate = "1984"
        original.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(scene.model.saveCatalogNow())
        #expect(copy.userDate == "1984", "the content's date reached the other copy")
        copy.lifecycleStage = .archived
        copy.derivationKind = ArchivePromotion.derivationKind
        #expect(scene.model.saveCatalogNow())
        return (original, copy)
    }

    @Test("RED before #383 (WRITER): Save 1992 via the ORIGINAL's Inspector is refused inside a debounce window, during a hold, across a viewer flip — the archived copy keeps 1984 before and after relaunch")
    func writerThroughSQLite() async throws {
        let scene = try CutoverScene.make("twin_383_writer"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let (original, copy) = try storedTwins(scene)
        let model = scene.model
        func readOnly() -> Bool {
            model.archivedCopyFixingDate(of: original) != nil
        }

        // Inside the debounce window of another edit on the SAME record.
        original.userNotes = "typed just before the date"
        model.saveCatalogDebounced()
        #expect(InspectorDateEdit.save(entry: "1992", known: true, to: original, readOnly: readOnly()) == .refusedArchived)
        #expect(model.saveCatalogNow(), "the notes edit still commits")
        #expect(copy.userDate == "1984" && original.userDate == "1984")

        // During a job's write hold.
        #expect(await model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(InspectorDateEdit.clear(original, readOnly: readOnly()) == .refusedArchived)
        model.catalogStore.releaseWriteHold()

        // Across a viewer / master flip.
        model.updateReadOnlyFacts { $0.viewerRole = true }
        #expect(InspectorDateEdit.save(entry: "1993", known: true, to: original, readOnly: readOnly()) == .refusedArchived)
        model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(InspectorDateEdit.save(entry: "1992", known: true, to: original, readOnly: readOnly()) == .refusedArchived)
        #expect(model.saveCatalogNow())
        #expect(copy.userDate == "1984", "the archived copy keeps its filed date this session")

        let fresh = try await relaunch(scene)
        let backCopy = try #require(fresh.records.first { $0.id == copy.id })
        let backOriginal = try #require(fresh.records.first { $0.id == original.id })
        #expect(backCopy.userDate == "1984" && backCopy.userDateConfidence == UserDateConfidence.known.rawValue)
        #expect(backOriginal.userDate == "1984")
        #expect(backOriginal.userNotes == "typed just before the date")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    /// GH #528 made this defence stronger: the twin's date is now refused at
    /// the commit itself (it is put back to the filed date and never stored),
    /// so the propagation's in-memory decline no longer fires for this shape;
    /// the archived copy keeps 1984 in memory AND after relaunch.
    @Test("RED before #383 (DEFENCE): a date another path writes on the twin is not copied onto the archived copy; one honest log line")
    func propagationDeclines() async throws {
        let scene = try CutoverScene.make("twin_383_defence"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (original, copy) = try storedTwins(scene)
        original.userDate = "1992"   // any writer that judged only its own target
        #expect(scene.model.saveCatalogNow())
        #expect(copy.userDate == "1984", "an archived copy never takes another copy's date")
        #expect(copy.userDateConfidence == UserDateConfidence.known.rawValue)
        #expect(original.userDate == "1984", "GH #528: the twin's date is refused at commit")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Catalog store: REFUSED date on \(original.id.uuidString)"), "\(log.suffix(600))")
        #expect(log.contains("Use Update… on the archived copy"))
        if let c = scene.model.catalogCutover.committer { await c.repository.close() }
    }
}

// MARK: - Rename: any archived file, locked or not, changes name only through Update…

@MainActor
@Suite("Codex #383 — Catalog Rename refuses every Master Archive file, locked or not", .serialized)
struct ArchivedRenameRefusalTests {

    @Test("RED before #383: an UNLOCKED archive copy is refused ('use Update…'); file, record and index unchanged")
    func unlockedArchiveCopyRefused() throws {
        let a = try UpdateFixture.make("ren_unlocked", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Trip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        #expect(!MasterArchiveTestSupport.isLocked(a.absPath), "the fixture is the unlocked case Promote can leave")
        let manifest = UpdateFixture.data(a.sb.manifestURL)
        let journal = UpdateFixture.data(a.journalURL)
        let sink = InMemoryLogSink()
        do {
            _ = try withAppLog(sink) { try a.model.renameRecord(a.copy, toBaseName: "1992-xx-xx_Trip") }
            Issue.record("the rename should have been refused")
        } catch VideoScanModel.RenameError.archivedFile {
        } catch {
            Issue.record("wrong refusal: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(!FileManager.default.fileExists(atPath: (a.absPath as NSString).deletingLastPathComponent + "/1992-xx-xx_Trip.mov"))
        #expect(a.copy.fullPath == a.absPath && a.copy.filename == "1984-xx-xx_Trip.mov")
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest)
        #expect(UpdateFixture.data(a.journalURL) == journal)
        #expect(sink.lines.contains("Catalog: rename of 1984-xx-xx_Trip.mov refused — it is a Master Archive file; use Update…"))
        #expect(VideoScanModel.RenameError.archivedFile.errorDescription
                == "This file is in the Master Archive. Only Update… (right-click) changes an archived file's name — nothing was renamed.")
    }

    @Test("a file under the archive root that was never promoted is refused too; the promoted SOURCE still renames")
    func underRootRefusedSourceRenames() throws {
        let a = try UpdateFixture.make("ren_stray", relPath: "30_Video/1980-1989/1984/1984-xx-xx_Trip.mov", recordDate: "1984-xx-xx")
        defer { a.sb.cleanup() }
        let strayURL = a.sb.archiveRoot.appendingPathComponent("stray.mov")
        try Data("stray".utf8).write(to: strayURL)
        let stray = MasterArchiveTestSupport.makeRecord(path: strayURL.path)
        a.model.records.append(stray)
        #expect(throws: VideoScanModel.RenameError.self) { try a.model.renameRecord(stray, toBaseName: "stray2") }
        #expect(FileManager.default.fileExists(atPath: strayURL.path) && stray.filename == "stray.mov")
        _ = try a.model.renameRecord(a.source, toBaseName: "Dad Thanksgiving 1984")
        #expect(a.source.filename == "Dad Thanksgiving 1984.mov")
    }
}
