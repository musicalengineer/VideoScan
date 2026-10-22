// PruneCuratedSurvivesTests.swift
// I8, end to end (codex review 2026-10-21 test gap): the prune path carries
// no note on its own — notes, stars, people, dates and places are keyed by
// the whole-file digest, and R1 requires the copy's digest to BE the archive
// file's. Prove it through the real store: UNSAVED edits on the copy, the
// copy trashed through the real prune path, the catalog committed and
// relaunched from catalog.sqlite, every value on the archive file's record.
// ISOLATION: a CutoverScene sandbox (its own catalog.sqlite); the file
// operation is a sandbox "Trash"; no real volume, no real Trash.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Prune — I8: curation survives the move (catalog.sqlite)", .serialized)
@MainActor
struct PruneCuratedSurvivesTests {

    @Test("I8: unsaved note, star, person, date and place on a trashed copy are on the archive file after a commit and relaunch")
    func unsavedCurationOnTheCopySurvivesTheMove() async throws {
        let scene = try CutoverScene.make("prune_i8"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        model.mediaLedger = MediaLedger(directory: scene.folder.appendingPathComponent("ledger", isDirectory: true))
        let media = scene.folder.appendingPathComponent("media", isDirectory: true)
        let archiveDir = media.appendingPathComponent("Archive", isDirectory: true)
        let copyDir = media.appendingPathComponent("copies", isDirectory: true)
        let trash = media.appendingPathComponent("FakeTrash", isDirectory: true)
        for dir in [archiveDir, copyDir, trash] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let archiveURL = try MasterArchiveTestSupport.writeBlob(at: archiveDir.appendingPathComponent("test_i8.mov"),
                                                                bytes: 32 * 1024, seed: 52)
        let copyURL = copyDir.appendingPathComponent("test_i8.mov")
        try FileManager.default.copyItem(at: archiveURL, to: copyURL)
        let digest = try scene.sha256(archiveURL)
        let size = Int64(32 * 1024)

        // Valid row shapes from the fixture (a bare VideoRecord is not a committable row).
        let archive = try scene.freshCopy(of: .healthy, path: archiveURL.path)
        archive.sizeBytes = size
        archive.derivationKind = VideoRecord.archivePromotionDerivationKind
        archive.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: size)
        let copy = try scene.freshCopy(of: .healthy, path: copyURL.path)
        copy.sizeBytes = size
        for r in [archive, copy] {   // the fixture shape's curation must not mask the copy's edits
            r.userNotes = ""; r.starRating = 0; r.confirmedByUserPeople = []; r.userDate = nil; r.userPlace = nil
            r.userDateConfidence = nil; r.userPlaceConfidence = nil
        }
        let copyFixity = try #require(ContentFixity.captured(path: copyURL.path, digest: digest, byteCount: size))
        copy.contentFixity = copyFixity
        // The copy is the promotion source the archive copy names (the store
        // requires an archive copy to name a stored source row): source first.
        archive.derivedFrom = copy.id
        model.records.append(copy)
        try #require(model.saveCatalogNow(), "fixture: the source row is in catalog.sqlite")
        model.records.append(archive)
        let stored = model.saveCatalogNow()
        try? await Task.sleep(nanoseconds: 400_000_000)
        try #require(stored, "fixture: the two rows are in catalog.sqlite — \(model.dashboard.consoleLines.suffix(6).joined(separator: " | "))")

        // UNSAVED edits on the copy row.
        let person = ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_790_000_000))
        copy.userNotes = "Grandpa's 1952 Christmas — the tree in the front room"
        copy.starRating = 3
        copy.confirmedByUserPeople = [person]
        copy.userDate = "1952-12-25"
        copy.userDateConfidence = UserDateConfidence.known.rawValue
        copy.userPlace = "Middlefield, MA"
        copy.userPlaceConfidence = UserPlaceConfidence.known.rawValue

        let shown = await model.prunePlan(batch: nil, isOnline: { _ in true }).shown()
        try #require(shown.offeredIDs == [copy.id], "fixture: the copy is offered — \(shown)")
        let mover = PruneApplyTests.Mover(trash: trash)
        let out = await model.applyPrune(shown: shown, selected: [copy.id], batch: nil, batchID: "i8",
                                         hooks: PruneApplyTests.hooks(mover))
        try #require(out.trashed == 1, "\(out)")
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))

        #expect(model.saveCatalogNow())
        try await scene.relaunch()
        let kept = try #require(model.records.first { $0.id == archive.id }, "the archive file's record after relaunch")
        #expect(kept.userNotes.contains("Grandpa's 1952 Christmas"), "note: \(kept.userNotes)")
        #expect(kept.starRating == 3, "star: \(kept.starRating)")
        #expect(kept.confirmedByUserPeople.contains { $0.name == "Donna" }, "people: \(kept.confirmedByUserPeople)")
        #expect(kept.userDate == "1952-12-25", "date: \(kept.userDate ?? "nil")")
        #expect(kept.userPlace == "Middlefield, MA", "place: \(kept.userPlace ?? "nil")")
    }
}
