// UpdateCatalogTests.swift
// The ONE door for "files were moved outside the app" (Rick 2026-08-17):
// rescan-with-preview → Apply, cross-target identity relink, ambiguity that
// is never guessed, archive protection, the "looks moved" prompt, and the
// scale/isolation dimensions of the five-dimension checklist.
//
// Isolated: fresh VideoScanModel() instances, temp directories, injected
// CatalogStore(directory:) where a snapshot is exercised — no real prefs,
// no App Support.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Fixture helpers (private per-file, mirroring ScanMergeMoveIdentityTests)

private func makeRecord(path: String, md5: String = "", sizeBytes: Int64 = 1_000_000,
                        contentHash: String = "") -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = sizeBytes
    r.partialMD5 = md5
    r.contentHash = contentHash
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

@MainActor
private func makePipelineModel() -> VideoScanModel {
    let model = VideoScanModel()
    var opts = ScanOptions()
    opts.skipSmallFiles = false
    opts.skipChecksums = false       // fingerprints REQUIRE partialMD5
    opts.probeExtensionless = false
    model.scanOptions = opts
    return model
}

private func makeTempDir(_ label: String) throws -> URL {
    var dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_updcat_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}

private func distinctBytes(_ index: Int) -> Data {
    Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &+ index &* 31) })
}

/// Run one full Update Catalog cycle on `target`: open → Preview → wait
/// for the deferred scan → return the previewed row.
@MainActor
private func previewThroughTheDoor(_ model: VideoScanModel, target: CatalogScanTarget) async throws -> UpdateCatalogRow {
    model.openUpdateCatalog(preselecting: [target.id])
    model.startUpdateCatalogPreview()
    _ = await target.scanTask?.value
    let row = try #require(model.updateCatalogRows.first { $0.id == target.id })
    return row
}

private func previewOf(_ row: UpdateCatalogRow) -> VideoScanModel.ScanMergePreview? {
    if case .previewed(let p) = row.phase { return p }
    return nil
}

private func applied(_ row: UpdateCatalogRow) -> UpdateCatalogApplySummary? {
    if case .applied(let s) = row.phase { return s }
    return nil
}

// MARK: - The door: preview → apply (pipeline)

@Suite("Update Catalog — the door", .serialized)
struct UpdateCatalogDoorTests {

    // Rename inside one target: Preview says moved=1 new=0 missing=0, the
    // catalog is UNCHANGED until Apply, then the same record (id, instance,
    // curation) lives at the new path with a journey line, no dup, no prune.
    @Test @MainActor
    func relinkWithinTargetThroughPreviewThenApply() async throws {
        let dir = try makeTempDir("rename")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("1987-tape-a.mov")
        try distinctBytes(1).write(to: oldURL)
        try distinctBytes(2).write(to: dir.appendingPathComponent("anchor.mov"))

        let model = makePipelineModel()
        let t1 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1]
        model.startTarget(t1)
        _ = await t1.scanTask?.value
        let original = try #require(model.records.first { $0.fullPath == oldURL.path })
        let originalID = original.id
        original.userNotes = "Donna on the porch"
        original.starRating = 3
        original.tags = ["Gold"]

        let newURL = dir.appendingPathComponent("1987-tape-a-RENAMED.mov")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let scannedBefore = t1.lastScannedDate

        let row = try await previewThroughTheDoor(model, target: t1)
        let p = try #require(previewOf(row), "Row must be previewed after the deferred scan (phase=\(row.phase))")
        #expect(p.moved == 1 && p.new == 0 && p.missing == 0 && p.unchanged == 1,
                "Preview must say 1 moved, 0 new, 0 missing, 1 unchanged (got moved=\(p.moved) new=\(p.new) missing=\(p.missing) unchanged=\(p.unchanged))")
        #expect(p.relinks == [VideoScanModel.ScanMergeRelinkPreview(oldPath: oldURL.path, newPath: newURL.path, crossRoot: false)])
        // NOTHING committed yet.
        #expect(model.records.contains { $0.fullPath == oldURL.path && $0.id == originalID },
                "Preview must not touch the catalog")
        #expect(t1.lastScannedDate == scannedBefore && t1.status == .idle,
                "lastScannedDate is stamped on Apply, not Preview; the target rests idle meanwhile")

        await model.applyUpdateCatalog()
        let doneRow = try #require(model.updateCatalogRows.first { $0.id == t1.id })
        let summary = try #require(applied(doneRow))
        #expect(summary.moved == 1 && summary.new == 0 && summary.pruned == 0 && summary.unchanged == 1,
                "Apply must equal Preview (got \(summary))")
        #expect(model.records.count == 2, "No duplicate, no prune")
        let after = try #require(model.records.first { $0.fullPath == newURL.path })
        #expect(after.id == originalID && after === original)
        #expect(after.userNotes == "Donna on the porch" && after.starRating == 3 && after.tags == ["Gold"])
        #expect(after.originalFullPath == oldURL.path)
        #expect(after.notes.contains("Moved from \(oldURL.path) to \(newURL.path) (relinked by Update Catalog)"))
        #expect(t1.lastScannedDate != scannedBefore && t1.status == .complete)
        #expect(model.updateCatalogPendingMerges.isEmpty, "Parked results are consumed by Apply")
    }

    // Cross-target: a file moved from target A's folder to target B's
    // folder; rescanning B through the door reunites B's new file with A's
    // record — moved=1 new=0 missing=0 — and A's later preview shows nothing
    // to prune.
    @Test @MainActor
    func crossTargetRelinkReunitesRecord() async throws {
        let rootA = try makeTempDir("A")
        let rootB = try makeTempDir("B")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let tapeA = rootA.appendingPathComponent("tape-07.mkv")
        try distinctBytes(7).write(to: tapeA)
        try distinctBytes(8).write(to: rootA.appendingPathComponent("anchorA.mov"))
        try distinctBytes(9).write(to: rootB.appendingPathComponent("anchorB.mov"))

        let model = makePipelineModel()
        let tA = CatalogScanTarget(searchPath: rootA.path)
        let tB = CatalogScanTarget(searchPath: rootB.path)
        model.scanTargets = [tA, tB]
        model.startTarget(tA)
        _ = await tA.scanTask?.value
        model.startTarget(tB)
        _ = await tB.scanTask?.value
        let rec = try #require(model.records.first { $0.fullPath == tapeA.path })
        let recID = rec.id
        rec.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        rec.audioTranscript = "porch"

        let tapeB = rootB.appendingPathComponent("moved/tape-07.mkv")
        try FileManager.default.createDirectory(at: tapeB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tapeA, to: tapeB)

        let row = try await previewThroughTheDoor(model, target: tB)
        let p = try #require(previewOf(row))
        #expect(p.moved == 1 && p.new == 0 && p.missing == 0,
                "Cross-target preview: moved=1 new=0 missing=0 (got moved=\(p.moved) new=\(p.new) missing=\(p.missing))")
        #expect(p.relinks.first?.crossRoot == true)

        await model.applyUpdateCatalog()
        let reunited = try #require(model.records.first { $0.fullPath == tapeB.path })
        #expect(reunited.id == recID && reunited === rec, "The record is REUNITED, not duplicated")
        #expect(reunited.confirmedByUserPeople.map(\.name) == ["Donna"] && reunited.audioTranscript == "porch")
        #expect(reunited.originalFullPath == tapeA.path)
        #expect(!model.records.contains { $0.fullPath == tapeA.path }, "No ghost at the old path")
        #expect(model.records.count == 3)

        // A's later rescan: nothing missing (the record already left).
        model.closeUpdateCatalog()
        let rowA = try await previewThroughTheDoor(model, target: tA)
        let pA = try #require(previewOf(rowA))
        #expect(pA.missing == 0 && pA.moved == 0 && pA.new == 0 && pA.unchanged == 1)
        model.closeUpdateCatalog()
    }

    // Closing the sheet discards parked results: the deferred scan's
    // results NEVER commit behind the user's back.
    @Test @MainActor
    func closingTheSheetDiscardsParkedResults() async throws {
        let dir = try makeTempDir("close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("a.mov")
        try distinctBytes(11).write(to: oldURL)
        let model = makePipelineModel()
        let t1 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1]
        model.startTarget(t1)
        _ = await t1.scanTask?.value
        let originalID = try #require(model.records.first).id
        try FileManager.default.moveItem(at: oldURL, to: dir.appendingPathComponent("b.mov"))

        let row = try await previewThroughTheDoor(model, target: t1)
        #expect(previewOf(row) != nil)
        model.closeUpdateCatalog()
        #expect(model.updateCatalogPendingMerges.isEmpty && model.updateCatalogRows.isEmpty
                && model.updateCatalogDeferredRoots.isEmpty && !model.showUpdateCatalogSheet)
        #expect(model.records.first?.fullPath == oldURL.path && model.records.first?.id == originalID,
                "Catalog untouched after close")
    }

    // Empty discovery through the door: the row reads "nothing to update"
    // and Apply is a harmless no-op (an empty scan never prunes).
    @Test @MainActor
    func emptyDiscoveryIsNothingToUpdate() async throws {
        let dir = try makeTempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makePipelineModel()
        let t1 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1]
        model.records = [makeRecord(path: dir.appendingPathComponent("ghost.mov").path, md5: "g", sizeBytes: 5)]
        let row = try await previewThroughTheDoor(model, target: t1)
        let p = try #require(previewOf(row))
        #expect(!p.note.isEmpty && p.missing == 0)
        await model.applyUpdateCatalog()
        #expect(model.records.count == 1, "Empty discovery never prunes")
        model.closeUpdateCatalog()
    }

    // Read-only viewer mode: the door does not open.
    @Test @MainActor
    func readOnlyModeKeepsTheDoorShut() {
        let model = VideoScanModel()
        model.isReadOnly = true
        model.scanTargets = [CatalogScanTarget(searchPath: "/tmp")]
        model.openUpdateCatalog()
        #expect(!model.showUpdateCatalogSheet && model.updateCatalogRows.isEmpty)
    }

    // Retired and scratch targets are never listed (scan gates unchanged).
    @Test @MainActor
    func retiredAndScratchTargetsAreNotEligible() {
        let model = VideoScanModel()
        let live = CatalogScanTarget(searchPath: "/tmp/live")
        let retired = CatalogScanTarget(searchPath: "/tmp/retired")
        retired.retiredAt = Date()
        let scratch = CatalogScanTarget(searchPath: "/Volumes/VideoScan_Temp")
        model.scanTargets = [live, retired, scratch]
        let eligible = model.updateCatalogEligibleTargets().map(\.id)
        #expect(eligible == [live.id])
    }
}

// MARK: - Merge semantics (in-memory, commitScanResults / previewScanMerge)

@Suite("Update Catalog — relink semantics")
struct UpdateCatalogRelinkSemanticsTests {

    // Two identical new files for one missing record → NOT relinked, listed
    // as ambiguous; the missing record is pruned only via the ordinary
    // (tripwire-guarded) path and both new files land as new records.
    @Test @MainActor
    func ambiguityIsListedNotGuessed() async throws {
        let vids = try makeTempDir("ambig")
        defer { try? FileManager.default.removeItem(at: vids) }
        let model = VideoScanModel()
        let gone = makeRecord(path: vids.appendingPathComponent("orig.mov").path, md5: "same", sizeBytes: 4242)
        gone.userNotes = "curated"
        model.records = [gone]
        let n1 = makeRecord(path: vids.appendingPathComponent("copy-1.mov").path, md5: "same", sizeBytes: 4242)
        let n2 = makeRecord(path: vids.appendingPathComponent("copy-2.mov").path, md5: "same", sizeBytes: 4242)

        let preview = await model.previewScanMerge(root: vids.path, targetRecords: [n1, n2], scanWasComplete: true)
        #expect(preview.moved == 0 && preview.new == 2 && preview.missing == 1)
        #expect(preview.ambiguous == [ScanMergeAmbiguity(
            addedPaths: [n1.fullPath, n2.fullPath].sorted(),
            candidatePaths: [gone.fullPath])])

        let outcome = await model.commitScanResults(root: vids.path, volName: "X",
                                                    targetRecords: [n1, n2], scanWasComplete: true)
        #expect(outcome.moved == 0 && outcome.ambiguous == 1 && outcome.pruned == 1)
        #expect(model.records.count == 2 && model.records.allSatisfy { $0.userNotes.isEmpty },
                "Neither new file may inherit the missing record's curation by guesswork")
    }

    // Two identical missing records for one new file → ambiguous too.
    @Test func severalMissingForOneNewIsAmbiguous() {
        let fp = ScanMergeFingerprint(partialMD5: "m", sizeBytes: 10)
        let r = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [ScanMergeAddedFile(path: "/root/new/x.mov", fingerprint: fp)],
            candidates: [
                ScanMergeMoveCandidate(path: "/root/a/one.mov", fingerprint: fp, sameRoot: true),
                ScanMergeMoveCandidate(path: "/root/b/two.mov", fingerprint: fp, sameRoot: true),
            ])
        #expect(r.adoptions.isEmpty && r.ambiguous.count == 1)
        #expect(r.ambiguous.first?.candidatePaths == ["/root/a/one.mov", "/root/b/two.mov"])
    }

    // Structural evidence still pairs: a same-root rename beats an offline
    // cross-root copy; a filename bijection pairs a moved folder of twins.
    @Test func structuralEvidencePairsWithoutGuessing() {
        let fp = ScanMergeFingerprint(partialMD5: "m", sizeBytes: 10)
        let sameRootWins = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [ScanMergeAddedFile(path: "/root/renamed.mov", fingerprint: fp)],
            candidates: [
                ScanMergeMoveCandidate(path: "/root/old.mov", fingerprint: fp, sameRoot: true),
                ScanMergeMoveCandidate(path: "/shelf/old.mov", fingerprint: fp, sameRoot: false),
            ])
        #expect(sameRootWins.adoptions == ["/root/renamed.mov": "/root/old.mov"] && sameRootWins.ambiguous.isEmpty,
                "Same-root rename is evidence; the offline copy simply stays missing")

        let twins = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [
                ScanMergeAddedFile(path: "/root/Christmas/a.mov", fingerprint: fp),
                ScanMergeAddedFile(path: "/root/Christmas/b.mov", fingerprint: fp),
            ],
            candidates: [
                ScanMergeMoveCandidate(path: "/root/Xmas/a.mov", fingerprint: fp, sameRoot: true),
                ScanMergeMoveCandidate(path: "/root/Xmas/b.mov", fingerprint: fp, sameRoot: true),
            ])
        #expect(twins.adoptions == ["/root/Christmas/a.mov": "/root/Xmas/a.mov",
                                    "/root/Christmas/b.mov": "/root/Xmas/b.mov"] && twins.ambiguous.isEmpty)

        let noNames = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [
                ScanMergeAddedFile(path: "/root/new/p.mov", fingerprint: fp),
                ScanMergeAddedFile(path: "/root/new/q.mov", fingerprint: fp),
            ],
            candidates: [
                ScanMergeMoveCandidate(path: "/root/old/x.mov", fingerprint: fp, sameRoot: true),
                ScanMergeMoveCandidate(path: "/root/old/y.mov", fingerprint: fp, sameRoot: true),
            ])
        #expect(noNames.adoptions.isEmpty && noNames.ambiguous.count == 1,
                "Two identical files with no name evidence are ambiguous")
    }

    // contentHash disagreement vetoes a partialMD5+size match; agreement or
    // absence on either side does not.
    @Test func contentHashDisagreementVetoesMatch() {
        let fp = ScanMergeFingerprint(partialMD5: "m", sizeBytes: 10)
        let veto = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [ScanMergeAddedFile(path: "/root/new.mov", fingerprint: fp, contentHash: "v1:aaa")],
            candidates: [ScanMergeMoveCandidate(path: "/root/old.mov", fingerprint: fp, sameRoot: true, contentHash: "v1:bbb")])
        #expect(veto.adoptions.isEmpty && veto.ambiguous.isEmpty,
                "Different signatures = different files: no relink and nothing to review")
        let agree = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [ScanMergeAddedFile(path: "/root/new.mov", fingerprint: fp, contentHash: "v1:aaa")],
            candidates: [ScanMergeMoveCandidate(path: "/root/old.mov", fingerprint: fp, sameRoot: true, contentHash: "v1:aaa")])
        #expect(agree.adoptions == ["/root/new.mov": "/root/old.mov"])
        let unknown = VideoScanModel.matchMovedFilesWithAmbiguity(
            added: [ScanMergeAddedFile(path: "/root/new.mov", fingerprint: fp)],
            candidates: [ScanMergeMoveCandidate(path: "/root/old.mov", fingerprint: fp, sameRoot: true, contentHash: "v1:aaa")])
        #expect(unknown.adoptions == ["/root/new.mov": "/root/old.mov"],
                "A side without a signature neither confirms nor vetoes")
    }

    // Archive copies are app-managed: never a relink SOURCE (derivationKind
    // == archivePromotion, or living under the Master Archive root) and a
    // file inside the Master Archive never ADOPTS a missing record.
    @Test @MainActor
    func archiveCopiesAreNeverRelinked() async throws {
        let vids = try makeTempDir("arcvids")
        let arc = try makeTempDir("arcroot")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: arc)
        }
        let model = VideoScanModel()
        let archiveRoot = arc.appendingPathComponent("Breen_Family_Archive")
        model.masterArchive = MasterArchiveDesignation(targetPath: arc.path, rootPath: archiveRoot.path)

        // (1) archive copy by derivationKind, file gone
        let copy = makeRecord(path: vids.appendingPathComponent("elsewhere/copy.mov").path, md5: "c1", sizeBytes: 100)
        copy.derivationKind = ArchivePromotion.derivationKind
        // (2) record under the Master Archive root, file gone
        let inArchive = makeRecord(path: archiveRoot.appendingPathComponent("1990/x.mov").path, md5: "c2", sizeBytes: 200)
        // (3) ordinary missing record — control
        let plain = makeRecord(path: vids.appendingPathComponent("gone/plain.mov").path, md5: "c3", sizeBytes: 300)
        model.records = [copy, inArchive, plain]

        let n1 = makeRecord(path: vids.appendingPathComponent("new/copy.mov").path, md5: "c1", sizeBytes: 100)
        let n2 = makeRecord(path: vids.appendingPathComponent("new/x.mov").path, md5: "c2", sizeBytes: 200)
        let n3 = makeRecord(path: vids.appendingPathComponent("new/plain.mov").path, md5: "c3", sizeBytes: 300)
        let outcome = await model.commitScanResults(root: vids.appendingPathComponent("new").path, volName: "X",
                                                    targetRecords: [n1, n2, n3], scanWasComplete: true)
        #expect(outcome.moved == 1, "Only the plain record relinks (got \(outcome.moved))")
        #expect(plain.fullPath == n3.fullPath)
        #expect(copy.fullPath.hasSuffix("elsewhere/copy.mov") && inArchive.fullPath.hasPrefix(archiveRoot.path),
                "Archive records stay exactly where they were")
        #expect(model.records.contains { $0 === n1 } && model.records.contains { $0 === n2 },
                "The new files land as fresh records")

        // (4) a NEW file inside the Master Archive never adopts.
        let model2 = VideoScanModel()
        model2.masterArchive = MasterArchiveDesignation(targetPath: arc.path, rootPath: archiveRoot.path)
        let missing = makeRecord(path: vids.appendingPathComponent("src.mov").path, md5: "c4", sizeBytes: 400)
        model2.records = [missing]
        let arcNew = makeRecord(path: archiveRoot.appendingPathComponent("1991/src.mov").path, md5: "c4", sizeBytes: 400)
        let o2 = await model2.commitScanResults(root: archiveRoot.path, volName: "Arc",
                                                targetRecords: [arcNew], scanWasComplete: true)
        #expect(o2.moved == 0 && missing.fullPath == vids.appendingPathComponent("src.mov").path
                && model2.records.contains { $0 === arcNew })
    }

    // Retire witnesses / records under retired targets are never candidates
    // — an offline shelf drive is not evidence its file moved.
    @Test @MainActor
    func retiredWitnessesAreNeverRelinked() async throws {
        let vids = try makeTempDir("retvids")
        let shelf = try makeTempDir("shelf")
        let elsewhere = try makeTempDir("elsewhere")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: shelf)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let model = VideoScanModel()
        let retiredTarget = CatalogScanTarget(searchPath: shelf.path)
        retiredTarget.retiredAt = Date()
        model.scanTargets = [CatalogScanTarget(searchPath: vids.path), retiredTarget]
        let onShelf = makeRecord(path: shelf.appendingPathComponent("tape.mov").path, md5: "s1", sizeBytes: 50)
        let witness = makeRecord(path: elsewhere.appendingPathComponent("w.mov").path, md5: "s2", sizeBytes: 60)
        witness.archiveStage = .manuallyDeleted
        model.records = [onShelf, witness]
        let n1 = makeRecord(path: vids.appendingPathComponent("tape.mov").path, md5: "s1", sizeBytes: 50)
        let n2 = makeRecord(path: vids.appendingPathComponent("w.mov").path, md5: "s2", sizeBytes: 60)
        let outcome = await model.commitScanResults(root: vids.path, volName: "X",
                                                    targetRecords: [n1, n2], scanWasComplete: true)
        #expect(outcome.moved == 0 && outcome.ambiguous == 0)
        #expect(model.records.count == 4)
    }

    // Missing with no match: prune only behind the tripwire — the preview
    // predicts the tripwire and Apply fires it (snapshot written first).
    @Test @MainActor
    func missingWithoutMatchPrunesOnlyBehindTripwire() async throws {
        let store = try makeTempDir("store")
        let vids = try makeTempDir("prune")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: vids)
        }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: store)
        let seeds = (0..<100).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path, md5: "k\($0)", sizeBytes: Int64(100 + $0)) }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)
        let fresh = (0..<40).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path, md5: "k\($0)", sizeBytes: Int64(100 + $0)) }

        let preview = await model.previewScanMerge(root: vids.path, targetRecords: fresh, scanWasComplete: true)
        #expect(preview.missing == 60 && preview.moved == 0 && preview.new == 0 && preview.unchanged == 40)
        #expect(preview.tripwireWouldFire, "60 of 100 must predict the tripwire")
        #expect(model.records.count == 100, "Preview prunes nothing")

        let outcome = await model.commitScanResults(root: vids.path, volName: "X", targetRecords: fresh, scanWasComplete: true)
        #expect(outcome.tripwireFired && outcome.pruned == 60 && outcome.snapshotPath != nil)
        #expect(model.records.count == 40)
    }

    // Preview equals Apply on a mixed scenario (moved + new + missing +
    // unchanged + ambiguous), when the catalog does not change in between.
    @Test @MainActor
    func previewEqualsApply() async throws {
        let vids = try makeTempDir("mixed")
        defer { try? FileManager.default.removeItem(at: vids) }
        let model = VideoScanModel()
        let unchangedPath = vids.appendingPathComponent("stay.mov")
        try distinctBytes(1).write(to: unchangedPath)   // exists → not "genuinely gone"
        let stay = makeRecord(path: unchangedPath.path, md5: "u", sizeBytes: 64)
        let movedOld = makeRecord(path: vids.appendingPathComponent("old/m.mov").path, md5: "m", sizeBytes: 10)
        let goneRec = makeRecord(path: vids.appendingPathComponent("gone.mov").path, md5: "g", sizeBytes: 11)
        let amb = makeRecord(path: vids.appendingPathComponent("amb.mov").path, md5: "a", sizeBytes: 12)
        model.records = [stay, movedOld, goneRec, amb]

        let fresh = [
            makeRecord(path: unchangedPath.path, md5: "u", sizeBytes: 64),
            makeRecord(path: vids.appendingPathComponent("new/m.mov").path, md5: "m", sizeBytes: 10),
            makeRecord(path: vids.appendingPathComponent("brand-new.mov").path, md5: "n", sizeBytes: 13),
            makeRecord(path: vids.appendingPathComponent("amb-1.mov").path, md5: "a", sizeBytes: 12),
            makeRecord(path: vids.appendingPathComponent("amb-2.mov").path, md5: "a", sizeBytes: 12),
        ]
        let p = await model.previewScanMerge(root: vids.path, targetRecords: fresh, scanWasComplete: true)
        let outcome = await model.commitScanResults(root: vids.path, volName: "X", targetRecords: fresh, scanWasComplete: true)
        let s = UpdateCatalogApplySummary(outcome: outcome)
        #expect(p.moved == 1 && p.new == 3 && p.missing == 2 && p.unchanged == 1 && p.ambiguous.count == 1,
                "Preview: moved=\(p.moved) new=\(p.new) missing=\(p.missing) unchanged=\(p.unchanged) ambiguous=\(p.ambiguous.count)")
        #expect(s.moved == p.moved && s.new == p.new && s.pruned == p.missing
                && s.unchanged == p.unchanged && s.ambiguous == p.ambiguous.count,
                "Apply must equal Preview: \(s)")
    }
}

// MARK: - "Looks moved" prompt

@Suite("Update Catalog — looks-moved prompt")
struct LooksMovedPromptTests {

    // Fires once per volume per session, only when the file is missing AND
    // the volume is mounted; opening the door from it preselects the target.
    @Test @MainActor
    func promptFiresOncePerMountedVolume() throws {
        let dir = try makeTempDir("looks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        let present = makeRecord(path: dir.appendingPathComponent("here.mov").path)
        try distinctBytes(3).write(to: URL(fileURLWithPath: present.fullPath))
        let missing1 = makeRecord(path: dir.appendingPathComponent("gone-1.mov").path)
        let missing2 = makeRecord(path: dir.appendingPathComponent("gone-2.mov").path)

        #expect(!model.noteMissingFileForUserAction(present), "A file that is there never prompts")
        #expect(model.looksMovedNotice == nil)

        #expect(model.noteMissingFileForUserAction(missing1))
        let notice = try #require(model.looksMovedNotice)
        #expect(notice.filename == "gone-1.mov" && notice.targetID == target.id)

        model.dismissLooksMovedNotice()
        #expect(model.noteMissingFileForUserAction(missing2), "Still 'looks moved' — but debounced")
        #expect(model.looksMovedNotice == nil, "Once per volume per session")

        model.resetLooksMovedDebounce()
        #expect(model.noteMissingFileForUserAction(missing2) && model.looksMovedNotice != nil,
                "Asking again re-arms the prompt")
        model.openUpdateCatalogFromLooksMoved()
        #expect(model.showUpdateCatalogSheet && model.looksMovedNotice == nil)
        #expect(model.updateCatalogRows.first { $0.id == target.id }?.isSelected == true,
                "The file's target is pre-checked")
        model.closeUpdateCatalog()
    }

    @Test @MainActor
    func promptNeverFiresForAnOfflineVolume() {
        let model = VideoScanModel()
        let offline = makeRecord(path: "/Volumes/NoSuchDrive_\(UUID().uuidString)/tape.mov")
        #expect(!model.noteMissingFileForUserAction(offline))
        #expect(model.looksMovedNotice == nil, "Offline volume = the offline story, not a move")
        #expect(model.looksMovedPromptedVolumes.isEmpty)
    }
}

// MARK: - Scale + isolation

@Suite("Update Catalog — scale + isolation")
struct UpdateCatalogScaleTests {

    // 100k records: the identity index is built once (dictionary grouping)
    // and every relink lookup is O(1). Budget covers matcher + a full
    // in-memory preview + commit of a 100k-record folder reorganize.
    @Test @MainActor
    func hundredThousandRelinksStayInsideBudget() async throws {
        let vids = try makeTempDir("scale")
        defer { try? FileManager.default.removeItem(at: vids) }
        let n = 100_000
        var added: [ScanMergeAddedFile] = []
        var cands: [ScanMergeMoveCandidate] = []
        added.reserveCapacity(n); cands.reserveCapacity(n)
        for i in 0..<n {
            let fp = ScanMergeFingerprint(partialMD5: "h\(i)", sizeBytes: Int64(1000 + i))
            added.append(ScanMergeAddedFile(path: "/root/new/clip\(i).mov", fingerprint: fp))
            cands.append(ScanMergeMoveCandidate(path: "/root/old/clip\(i).mov", fingerprint: fp, sameRoot: true))
        }
        let t0 = Date()
        let match = VideoScanModel.matchMovedFilesWithAmbiguity(added: added, candidates: cands)
        let matcherSecs = Date().timeIntervalSince(t0)
        #expect(match.adoptions.count == n && match.ambiguous.isEmpty)
        #expect(matcherSecs < 5, "Matcher over 100k unique groups took \(matcherSecs)s (budget 5 s)")

        // End to end: catalog of 100k under the root (all vanished — the
        // files never existed) + 100k fresh at new paths → 100k relinks.
        let model = VideoScanModel()
        model.records = (0..<n).map { makeRecord(path: vids.appendingPathComponent("old/clip\($0).mov").path, md5: "h\($0)", sizeBytes: Int64(1000 + $0)) }
        let fresh = (0..<n).map { makeRecord(path: vids.appendingPathComponent("new/clip\($0).mov").path, md5: "h\($0)", sizeBytes: Int64(1000 + $0)) }
        let t1 = Date()
        let preview = await model.previewScanMerge(root: vids.path, targetRecords: fresh, scanWasComplete: true)
        let previewSecs = Date().timeIntervalSince(t1)
        #expect(preview.moved == n && preview.missing == 0 && preview.new == 0)
        #expect(preview.relinks.count == VideoScanModel.ScanMergePreview.relinkListCap, "Display list is capped")
        let t2 = Date()
        let outcome = await model.commitScanResults(root: vids.path, volName: "X", targetRecords: fresh, scanWasComplete: true)
        let commitSecs = Date().timeIntervalSince(t2)
        #expect(outcome.moved == n && outcome.pruned == 0 && !outcome.tripwireFired)
        #expect(model.records.count == n)
        #expect(previewSecs < 30 && commitSecs < 30,
                "100k relink: preview \(previewSecs)s, commit \(commitSecs)s (budget 30 s each)")
    }

    // Poisoned state: a stale entry in the deferred-roots set (no live
    // session) must NOT turn an ordinary rescan into a silent no-commit;
    // and a stale looks-moved debounce entry never blocks a fresh model.
    @Test @MainActor
    func staleDeferredRootNeverParksAnOrdinaryScan() async throws {
        let dir = try makeTempDir("poison")
        defer { try? FileManager.default.removeItem(at: dir) }
        try distinctBytes(21).write(to: dir.appendingPathComponent("a.mov"))
        let model = makePipelineModel()
        let t1 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1]
        model.updateCatalogDeferredRoots.insert(PathScope.normalize(dir.path))   // poison
        #expect(!model.isUpdateCatalogDeferred(root: dir.path), "No live .scanning row → not deferred")
        model.startTarget(t1)
        _ = await t1.scanTask?.value
        #expect(model.records.count == 1 && t1.status == .complete,
                "The ordinary scan must commit despite the stale set entry")
        #expect(model.updateCatalogPendingMerges.isEmpty)
    }
}
