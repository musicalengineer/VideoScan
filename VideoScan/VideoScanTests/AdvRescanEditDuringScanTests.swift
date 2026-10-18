// AdvRescanEditDuringScanTests.swift
//
// Adversarial review 2026-10-18, item 1 (P1, invariant VOL-4): notes and
// stars typed WHILE a rescan runs were lost when the scan merged.
//
// Mechanism (pre-fix): `snapshotPreservedFieldsForRescan` copies every
// record's curated fields when the scan STARTS. When it ends,
// `applyPreservedFieldsAfterRescan` writes that scan-start copy onto the
// fresh records (re-reading only `archiveFixity` from the live record), and
// `commitScanResults` swaps the old instance out for the fresh one (and,
// since cutover B2.3, purges the old id in the same turn). So anything the
// person typed between scan start and the merge — a note, a star, a date,
// a Trash — was silently replaced by the scan-start copy. A scan of a big
// volume runs for hours; the Update Catalog preview can sit open longer.
//
// The contract pinned here: at the moment of replacement the LIVE record's
// curated values win, for every field in the preserved set — and the scan's
// own (technical) values still refresh.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     edits during the scan / during the merge's await / clears /
//             a Trash / a never-curated record; scan-derived fields refresh
//   SCALE     100k records through a merge, explicit time budget
//   ISOLATION every case in a temp folder or a CutoverScene sandbox
//   SENSOR    the SQLite round trip — the edit is in catalog.sqlite after a
//             relaunch (the commit path writes the merged value)
//   MEDIA     N/A — no media is opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Adv — an edit made while a rescan runs survives the merge", .serialized)
@MainActor
struct AdvRescanEditDuringScanTests {

    // MARK: Helpers

    /// A scratch scan root on disk (the complete merge checks the root is
    /// reachable before it prunes anything).
    private static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_adv_scan_edit_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A cataloged record that already carries curated values at scan start.
    private static func curatedRecord(path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.videoCodec = "h264-OLD"
        r.sizeBytes = 1_000
        r.userNotes = "typed before the scan"
        r.starRating = 1
        return r
    }

    /// What the scan produces for `path`: a new instance (new id), the
    /// file's technical values, no curated values at all.
    private static func freshProbe(path: String, codec: String = "h264-NEW", sizeBytes: Int64 = 2_000) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.videoCodec = codec
        r.sizeBytes = sizeBytes
        return r
    }

    private static let editedAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// The person curates `rec` — one edit per user-authored field class
    /// in RescanPreservedFields.
    private static func curate(_ rec: VideoRecord, in model: VideoScanModel) {
        model.setUserNotes("typed while the scan ran", for: rec)
        rec.starRating = 3
        rec.tags = ["Birthday"]
        rec.userDate = "1994-06"
        rec.userDateConfidence = "known"
        rec.userPlace = "Cape Cod"
        rec.userPlaceConfidence = "estimated"
        rec.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: editedAt)]
        rec.rejectedPeople = ["Matt"]
        rec.mediaDisposition = .important
        rec.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: editedAt)]
    }

    private static func expectCurated(_ rec: VideoRecord, _ where_: String) {
        let c = Comment(rawValue: where_)
        #expect(rec.userNotes == "typed while the scan ran", c)
        #expect(rec.starRating == 3, c)
        #expect(rec.tags == ["Birthday"], c)
        #expect(rec.userDate == "1994-06", c)
        #expect(rec.userDateConfidence == "known", c)
        #expect(rec.userPlace == "Cape Cod", c)
        #expect(rec.userPlaceConfidence == "estimated", c)
        #expect(rec.confirmedByUserPeople.map(\.name) == ["Donna"], c)
        #expect(rec.rejectedPeople == ["Matt"], c)
        #expect(rec.mediaDisposition == .important, c)
        #expect(rec.backupAttestations.count == 1, c)
    }

    // MARK: LOGIC

    /// The finding's exact shape: the scan starts, the person types a note
    /// and a star (and every other user-authored field), the scan ends and
    /// merges. The merged record must carry the edits.
    @Test func notesTypedDuringTheScanSurviveTheMerge() async throws {
        let root = try Self.makeRoot("during"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let original = Self.curatedRecord(path: root.appendingPathComponent("birthday.mov").path)
        model.records = [original]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)               // the scan starts
        Self.curate(original, in: model)                                 // the person curates meanwhile
        let fresh = Self.freshProbe(path: original.fullPath)             // the scan's record
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh]) // the scan ends
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: true)

        let merged = try #require(model.records.first { $0.fullPath == original.fullPath })
        #expect(merged === fresh, "precondition: the merge swapped in the fresh instance")
        Self.expectCurated(merged, "edit during the scan")
        #expect(merged.videoCodec == "h264-NEW", "the scan's technical values still refresh")
        #expect(merged.sizeBytes == 2_000)
    }

    /// A record with NOTHING curated at scan start (so no snapshot entry)
    /// gets its very first note and star while the scan runs.
    @Test func firstNoteOnAPlainRecordDuringTheScanSurvives() async throws {
        let root = try Self.makeRoot("first"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let plain = Self.freshProbe(path: root.appendingPathComponent("plain.mov").path, codec: "h264-OLD")
        model.records = [plain]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        Self.curate(plain, in: model)
        let fresh = Self.freshProbe(path: plain.fullPath)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: true)

        let merged = try #require(model.records.first { $0.fullPath == plain.fullPath })
        Self.expectCurated(merged, "first edit on a plain record")
    }

    /// The edit lands AFTER the preservation pass, while the complete merge
    /// is suspended in its existence sweep (the last await before the swap).
    @Test func editDuringTheMergeAwaitSurvives() async throws {
        let root = try Self.makeRoot("await"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let original = Self.curatedRecord(path: root.appendingPathComponent("reunion.mov").path)
        model.records = [original]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = Self.freshProbe(path: original.fullPath)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.userNotes == "typed before the scan", "precondition: preservation carried the scan-start value")

        model.scanMergeDuringExistenceChecksForTesting = { @MainActor in
            Self.curate(original, in: model)
        }
        defer { model.scanMergeDuringExistenceChecksForTesting = nil }
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: true)

        let merged = try #require(model.records.first { $0.fullPath == original.fullPath })
        Self.expectCurated(merged, "edit during the merge's await")
    }

    /// A clear is an edit too: a note and star REMOVED while the scan runs
    /// (before the preservation pass, and during the merge's await) must not
    /// come back from the scan-start copy.
    @Test func clearedDuringTheScanStaysCleared() async throws {
        let root = try Self.makeRoot("clear"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let early = Self.curatedRecord(path: root.appendingPathComponent("early.mov").path)
        let late = Self.curatedRecord(path: root.appendingPathComponent("late.mov").path)
        model.records = [early, late]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        model.setUserNotes("", for: early)
        early.starRating = 0
        let freshEarly = Self.freshProbe(path: early.fullPath)
        let freshLate = Self.freshProbe(path: late.fullPath)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [freshEarly, freshLate])

        model.scanMergeDuringExistenceChecksForTesting = { @MainActor in
            model.setUserNotes("", for: late)
            late.starRating = 0
        }
        defer { model.scanMergeDuringExistenceChecksForTesting = nil }
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [freshEarly, freshLate], scanWasComplete: true)

        for path in [early.fullPath, late.fullPath] {
            let merged = try #require(model.records.first { $0.fullPath == path })
            #expect(merged.userNotes.isEmpty, Comment(rawValue: path))
            #expect(merged.starRating == 0, Comment(rawValue: path))
        }
    }

    /// The scan saw the file, then the person moved it to the Trash before
    /// the merge. The merged row must keep the removal marker — never come
    /// back as a live row for a file that is in the Trash.
    @Test func trashedDuringTheScanStaysRemoved() async throws {
        let root = try Self.makeRoot("trash"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let original = Self.curatedRecord(path: root.appendingPathComponent("blurry.mov").path)
        model.records = [original]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = Self.freshProbe(path: original.fullPath)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        let marker = RemovalMarker.inTrash(movedAt: Self.editedAt, trashPath: "/Users/x/.Trash/blurry.mov",
                                           reason: .unspecified)
        original.removal = marker
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: false)

        let merged = try #require(model.records.first { $0.fullPath == original.fullPath })
        #expect(merged.removal == marker, "a Trash made during the scan is not undone by the merge")
        #expect(merged.isPurged)
    }

    /// Edge: two rows share the path — the active one (curated during the
    /// scan) and a kept `replacedAtPath` row behind it in `records`. The
    /// merged record takes the ACTIVE row's values and no removal marker.
    @Test func activeRowWinsOverAReplacedRowAtTheSamePath() async throws {
        let root = try Self.makeRoot("dup"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let path = root.appendingPathComponent("balanced.mov").path
        let active = Self.curatedRecord(path: path)
        let replaced = Self.curatedRecord(path: path)
        replaced.userNotes = "the replaced row's old note"
        replaced.removal = .removedFromCatalog(at: Self.editedAt, reason: .replacedAtPath)
        model.records = [active, replaced]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        Self.curate(active, in: model)
        let fresh = Self.freshProbe(path: path)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: false)

        #expect(fresh.removal == nil, "a stale removal marker never rides onto the fresh record")
        Self.expectCurated(fresh, "active row at a shared path")
    }

    /// Edge: the scan's own values are not clobbered by the live record. A
    /// never-curated record keeps the fresh probe's machine note (ffprobe
    /// stderr lands in `notes`), its new codec and size.
    @Test func scanDerivedValuesStillRefresh() async throws {
        let root = try Self.makeRoot("derived"); defer { try? FileManager.default.removeItem(at: root) }
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: root.path)
        let plain = Self.freshProbe(path: root.appendingPathComponent("broken.mov").path, codec: "h264-OLD")
        model.records = [plain]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = Self.freshProbe(path: plain.fullPath, codec: "", sizeBytes: 7)
        fresh.notes = MachineNote.line(author: .ffprobe, text: "moov atom not found")
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        _ = await model.commitScanResults(root: root.path, volName: "Adv",
                                          targetRecords: [fresh], scanWasComplete: true)

        let merged = try #require(model.records.first { $0.fullPath == plain.fullPath })
        #expect(merged.notes.contains("moov atom not found"), "the fresh probe's machine note stands")
        #expect(merged.videoCodec.isEmpty)
        #expect(merged.sizeBytes == 7)
    }

    // MARK: SENSOR — the SQLite commit path writes the merged value

    @Test func notesTypedDuringTheScanReachCatalogSQLite() async throws {
        let scene = try CutoverScene.make("adv_scan_edit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let original = try scene.record(.healthy)
        let path = original.fullPath
        let root = (path as NSString).deletingLastPathComponent
        let target = CatalogScanTarget(searchPath: root)

        model.snapshotPreservedFieldsForRescan(of: target)                  // the scan starts
        model.setUserNotes("adv sentinel — typed while the scan ran", for: original)
        original.starRating = 3
        model.saveCatalogDebounced()
        // The scan's fresh record: the file's values under a new id, no
        // curated values (blank them through the preserved-set carrier).
        let probed = try scene.freshCopy(of: .healthy, path: path)
        RescanPreservedFields(from: VideoRecord()).apply(to: probed)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [probed])
        _ = await model.commitScanResults(root: root, volName: "Fixture",
                                          targetRecords: [probed], scanWasComplete: false)
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())

        try await scene.relaunch()
        let atPath = try #require(model.records.first { $0.fullPath == path && $0.removal == nil })
        #expect(atPath.userNotes == "adv sentinel — typed while the scan ran")
        #expect(atPath.starRating == 3)
    }

    // MARK: SCALE — 100k records through the merge

    /// Every record curated at scan start AND edited during the scan: the
    /// live-wins pass at merge time must stay one O(records) pass.
    @Test("scale: 100k records edited during the scan merge within budget", .timeLimit(.minutes(1)))
    func scale_100kEditedDuringTheScanMergeWithinBudget() async {
        let model = VideoScanModel()
        let root = "/Volumes/AdvScale"
        let target = CatalogScanTarget(searchPath: root)
        var old: [VideoRecord] = []
        old.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.fullPath = "\(root)/\(i % 100)/clip\(i).mov"
            r.sizeBytes = Int64(i)
            r.userNotes = "before \(i)"
            r.starRating = 1
            old.append(r)
        }
        model.records = old
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        for r in old { r.userNotes = "during \(r.sizeBytes)"; r.starRating = 2 }
        let fresh = old.map { Self.freshProbe(path: $0.fullPath, sizeBytes: $0.sizeBytes) }
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await model.commitScanResults(root: root, volName: "AdvScale",
                                              targetRecords: fresh, scanWasComplete: false)
        }
        #expect(model.records.count == 100_000)
        #expect(fresh[0].userNotes == "during 0")
        #expect(fresh[99_999].userNotes == "during 99999")
        #expect(fresh.allSatisfy { $0.starRating == 2 })
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(3)),
                "100k partial merge took \(elapsed) — budget 3s")
    }
}
