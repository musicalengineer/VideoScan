import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #221: the Inspector never writes an archived record's date
//
// Rule 3 ("Archived means fixed"): only Update… changes an archived file's
// date, because Update… moves the folder, the filename and the manifest row
// with it. Before the fix the Inspector's "When was this?" field wrote
// `userDate` straight onto an archived record (the seam listed the Inspector
// as exempt), so the Date column followed while the archive's folder, name and
// index stayed put — two dates for one file.
//
// Dimensions:
//   logic      archived stage, a promoted copy and a file under the archive
//              root are refused (save, clear, confidence flip); a cataloged
//              control row is written; an unreadable entry is still
//              "couldn't read that", archived or not
//   writer     the refusal inside the debounce window of another edit on the
//              same record, during a write hold, across a viewer/master flip —
//              then a relaunch from catalog.sqlite shows the date as filed
//   sensor     InspectorDateView no longer assigns a date field at all (the
//              source scan in ArchivedDateReadOnlyTests lists InspectorDateEdit,
//              routed through the seam, instead)
//   scale / media: not applicable — one record, no media read.

@MainActor
@Suite("GH #221 — the Inspector refuses an archived record's date; Update… only", .serialized)
struct ArchivedInspectorDateTests {

    typealias F = DossierAdmissionFixtures

    // MARK: Logic

    @Test("RED before #221: Save on an Archived-stage row writes nothing; the date stays as filed")
    func saveOnArchivedIsRefused() throws {
        let sb = try F.Sandbox("insp_archived_save")
        defer { sb.cleanup() }
        let archived = sb.record("test_insp_archived.mov", stage: .archived, onDisk: false)
        archived.userDate = "1984"
        archived.userDateConfidence = UserDateConfidence.estimated.rawValue
        let before = try F.persisted(archived)
        let outcome = InspectorDateEdit.save(entry: "1992", known: true, to: archived,
                                             readOnly: sb.model.isDateReadOnly(archived))
        #expect(outcome == .refusedArchived)
        #expect(archived.userDate == "1984" && archived.userDateConfidence == UserDateConfidence.estimated.rawValue)
        #expect(F.changedKeys(before, try F.persisted(archived)).isEmpty)
    }

    @Test("RED before #221: Clear and an emptied field on an archived row remove nothing")
    func clearOnArchivedIsRefused() throws {
        let sb = try F.Sandbox("insp_archived_clear")
        defer { sb.cleanup() }
        let archived = sb.record("test_insp_archived_clear.mov", stage: .archived, onDisk: false)
        archived.userDate = "1984-06"
        archived.userDateConfidence = UserDateConfidence.known.rawValue
        let ro = sb.model.isDateReadOnly(archived)
        #expect(InspectorDateEdit.clear(archived, readOnly: ro) == .refusedArchived)
        #expect(InspectorDateEdit.save(entry: "   ", known: false, to: archived, readOnly: ro) == .refusedArchived)
        // The confidence picker re-saves the same text at the other confidence.
        #expect(InspectorDateEdit.save(entry: "1984-06", known: false, to: archived, readOnly: ro) == .refusedArchived)
        #expect(archived.userDate == "1984-06" && archived.userDateConfidence == UserDateConfidence.known.rawValue)
    }

    @Test("a promoted copy and a file under the archive root are refused whatever their stage; a cataloged row outside is written")
    func archiveElementsRefusedControlWritten() throws {
        let sb = try F.Sandbox("insp_elements")
        defer { sb.cleanup() }
        let root = sb.dir.appendingPathComponent("test_Archive", isDirectory: true).path
        sb.model.masterArchive = MasterArchiveDesignation(targetPath: sb.dir.path, rootPath: root)
        let copy = sb.record("test_copy.mov", stage: .cataloged, onDisk: false)
        copy.derivationKind = ArchivePromotion.derivationKind
        let inside = sb.record("test_inside.mov", stage: .cataloged, onDisk: false)
        inside.fullPath = root + "/30_Video/1990-1999/1992/test_inside.mov"
        let control = sb.record("test_control.mov", stage: .cataloged, onDisk: false)
        for rec in [copy, inside] {
            #expect(InspectorDateEdit.save(entry: "6/1992", known: false, to: rec,
                                           readOnly: sb.model.isDateReadOnly(rec)) == .refusedArchived)
            #expect(rec.userDate == nil, "\(rec.filename)")
        }
        #expect(InspectorDateEdit.save(entry: "6/1992", known: false, to: control,
                                       readOnly: sb.model.isDateReadOnly(control)) == .saved("1992-06"))
        #expect(control.userDate == "1992-06" && control.userDateConfidence == UserDateConfidence.estimated.rawValue)
        #expect(InspectorDateEdit.clear(control, readOnly: false) == .cleared)
        #expect(control.userDate == nil && control.userDateConfidence == nil)
        #expect(InspectorDateEdit.save(entry: "", known: false, to: control, readOnly: false) == .unchanged)
    }

    @Test("unreadable text is 'couldn't read that' on any row — archived rows are refused before nothing is parsed")
    func unreadableEntry() throws {
        let sb = try F.Sandbox("insp_unreadable")
        defer { sb.cleanup() }
        let control = sb.record("test_unreadable.mov", stage: .cataloged, onDisk: false)
        #expect(InspectorDateEdit.save(entry: "last summer", known: false, to: control, readOnly: false) == .unreadable)
        #expect(control.userDate == nil)
        let archived = sb.record("test_unreadable_arch.mov", stage: .archived, onDisk: false)
        #expect(InspectorDateEdit.save(entry: "last summer", known: false, to: archived, readOnly: true) == .refusedArchived)
    }

    @Test("TRUTH: an archived row's words say the filed date, how sure, and that only Update… changes it")
    func archivedWords() {
        let r = VideoRecord()
        r.lifecycleStage = .archived
        #expect(InspectorDateView.archivedFiledText(r)
                == "No date of yours on this file. Archived, so the date is fixed. Use Update… to change it.")
        r.userDate = "1984-06"
        r.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(InspectorDateView.archivedFiledText(r)
                == "Filed as 1984-06 (you're sure). Archived, so the date is fixed. Use Update… to change it.")
        r.userDateConfidence = UserDateConfidence.estimated.rawValue
        #expect(InspectorDateView.archivedFiledText(r).hasPrefix("Filed as 1984-06 (best guess)."))
    }

    // MARK: Writer (catalog.sqlite)

    /// Quit and launch again on the same folder (same shape as PublicMarkTests).
    private func relaunch(_ scene: CutoverScene) async throws -> VideoScanModel {
        if let committer = scene.model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    @Test("WRITER: refused inside the debounce window of a notes edit, during a write hold and across a viewer flip — the relaunch shows the filed date and the notes edit")
    func writerCasesThenRelaunch() async throws {
        let scene = try CutoverScene.make("insp_221_writer"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let archived = try scene.record(.healthy)
        archived.lifecycleStage = .archived
        archived.userDate = "1984"
        archived.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(scene.model.saveCatalogNow(), "the filed date is stored")
        let ro = scene.model.isDateReadOnly(archived)
        #expect(ro)

        // Inside the debounce window of another edit on the SAME record.
        archived.userNotes = "typed just before the date"
        scene.model.saveCatalogDebounced()
        #expect(InspectorDateEdit.save(entry: "1992", known: false, to: archived, readOnly: ro) == .refusedArchived)
        #expect(scene.model.saveCatalogNow(), "the notes edit still commits")

        // During a job's write hold.
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(InspectorDateEdit.clear(archived, readOnly: ro) == .refusedArchived)
        scene.model.catalogStore.releaseWriteHold()

        // Across a viewer / master flip: the seam does not depend on the role.
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        #expect(InspectorDateEdit.save(entry: "1993", known: true, to: archived,
                                       readOnly: scene.model.isDateReadOnly(archived)) == .refusedArchived)
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(InspectorDateEdit.save(entry: "1994", known: true, to: archived,
                                       readOnly: scene.model.isDateReadOnly(archived)) == .refusedArchived)
        #expect(scene.model.saveCatalogNow())

        let fresh = try await relaunch(scene)
        let back = try #require(fresh.records.first { $0.id == archived.id })
        #expect(back.userDate == "1984" && back.userDateConfidence == UserDateConfidence.known.rawValue)
        #expect(back.userNotes == "typed just before the date")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }
}
