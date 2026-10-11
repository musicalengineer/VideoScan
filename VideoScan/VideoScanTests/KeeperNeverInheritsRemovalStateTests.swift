// KeeperNeverInheritsRemovalStateTests.swift
// B5 (2026-10-11, docs/reviews/night/manually_deleted_959_classification_2026_10_11.md):
// `applyHumanMetadataInheritance` copied `archiveStage` from the copy being
// removed onto the copy being KEPT whenever the keeper's was `.none`. When
// the removed copy was already labelled `.manuallyDeleted`, the keeper took
// the label and vanished from the catalog view, the footer totals, the
// Archive Angel and Promote — the last visible copy of 6 files, two of them
// on FamilyArchive (BrocktonChristmas2010.mov, Donna-MyGirl-1984-Final.mov).
//
// The rule now: a stage carries to another copy only when it describes the
// FOOTAGE (how far along the archive path it is), never when it describes
// what happened to ONE FILE (Migrate could not copy it / labelled it
// deleted; it went to the Trash; it was deleted). Pinned three ways:
//   * the truth table for every ArchiveStage and LifecycleStage case —
//     written out by hand here, so a new case or a changed decision fails;
//   * the three real callers end to end: Delete Duplicates, the
//     "Archived — what next?" prune fold, and repair Confirm;
//   * the prune fold specifically: it carries AFTER the Trash routine has
//     stamped the removed copy `.trashed`, so an archive copy found by scan
//     (lifecycle `.cataloged`) used to inherit "Trashed".
//
// Dimensions: logic (truth table), sensor (each caller, end to end).
// Isolation: sandbox catalog stores + sandbox ledger; nothing global.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("A keeper never inherits a removal state", .serialized)
@MainActor
struct KeeperNeverInheritsRemovalStateTests {

    // MARK: The decision, written out (logic)

    /// ArchiveStage values that describe the footage — they may follow it.
    static let archiveStagesThatCarry: Set<ArchiveStage> = [.healthy, .masterAssigned, .backedUp, .readyForArchive, .archived]
    /// ArchiveStage values that describe one file's fate — never carried.
    static let archiveStagesThatNeverCarry: Set<ArchiveStage> = [.manuallyDeleted, .salvageFailed]
    static let lifecycleStagesThatNeverCarry: Set<LifecycleStage> = [.trashed, .deletedPermanently]

    @Test("every ArchiveStage case is classified, and the table is exactly the ruling")
    func archiveStageTableIsComplete() {
        let all = Set(ArchiveStage.allCases).subtracting([.none])
        #expect(Self.archiveStagesThatCarry.union(Self.archiveStagesThatNeverCarry) == all,
                "a new ArchiveStage needs a carry decision here")
        for stage in ArchiveStage.allCases {
            #expect(stage.travelsWithFootage == !Self.archiveStagesThatNeverCarry.contains(stage), "\(stage)")
        }
        for stage in LifecycleStage.allCases {
            #expect(stage.travelsWithFootage == !Self.lifecycleStagesThatNeverCarry.contains(stage), "\(stage)")
        }
    }

    @Test("truth table: a .none keeper takes a footage stage and never a per-file one")
    func archiveStageTruthTable() {
        let model = VideoScanModel()
        for stage in ArchiveStage.allCases where stage != .none {
            let keeper = VideoRecord(), removed = VideoRecord()
            removed.archiveStage = stage
            let carried = model.applyHumanMetadataInheritance(from: removed, to: keeper)
            if Self.archiveStagesThatNeverCarry.contains(stage) {
                #expect(keeper.archiveStage == .none, "\(stage) must never reach the keeper")
                #expect(!carried.contains("archive stage"), "\(stage): \(carried)")
            } else {
                #expect(keeper.archiveStage == stage, "\(stage) is the footage's progress — it carries")
                #expect(carried.contains("archive stage"))
            }
        }
    }

    @Test("truth table: a .cataloged keeper never takes Trashed or Deleted")
    func lifecycleStageTruthTable() {
        let model = VideoScanModel()
        for stage in LifecycleStage.allCases where stage != .cataloged {
            let keeper = VideoRecord(), removed = VideoRecord()
            removed.lifecycleStage = stage
            _ = model.applyHumanMetadataInheritance(from: removed, to: keeper)
            if Self.lifecycleStagesThatNeverCarry.contains(stage) {
                #expect(keeper.lifecycleStage == .cataloged, "\(stage) must never reach the keeper")
            } else {
                #expect(keeper.lifecycleStage == stage, "\(stage) carries as before")
            }
        }
    }

    @Test("a labelled-deleted copy still hands over Rick's marks — only the label stays behind")
    func marksStillCarryWithoutTheLabel() {
        let model = VideoScanModel()
        let keeper = VideoRecord(), removed = VideoRecord()
        removed.archiveStage = .manuallyDeleted
        removed.starRating = 3
        removed.userNotes = "Christmas at Brockton"
        let carried = model.applyHumanMetadataInheritance(from: removed, to: keeper)
        #expect(keeper.starRating == 3 && keeper.userNotes == "Christmas at Brockton")
        #expect(Set(carried) == ["star rating", "notes"], "\(carried)")
        #expect(keeper.archiveStage == .none)
    }

    // MARK: Delete Duplicates, end to end

    @Test("DELETE DUPLICATES: trashing a labelled-deleted extra leaves the keeper visible")
    func deleteDuplicatesKeeperStaysVisible() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeeperNoRemovalState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<120_000).map { UInt8($0 % 239) })
        let keeperURL = dir.appendingPathComponent("BrocktonChristmas2010.mov")
        let extraURL = dir.appendingPathComponent("BrocktonChristmas2010 copy.mov")
        try bytes.write(to: keeperURL)
        try bytes.write(to: extraURL)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        func dup(_ url: URL, _ d: DuplicateDisposition) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = url.lastPathComponent
            r.sizeBytes = Int64(bytes.count); r.partialMD5 = "m"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = dup(keeperURL, .keep)
        let extra = dup(extraURL, .extraCopy)
        extra.archiveStage = .manuallyDeleted          // Migrate's old false label
        extra.starRating = 3
        model.records = [keeper, extra]
        addVerifiedArchiveFamily(to: model, keeper: keeper)

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 1, "the extra is a proven copy and goes")
        #expect(FileManager.default.fileExists(atPath: keeperURL.path))
        #expect(keeper.archiveStage == .none, "the keeper took the extra's 'deleted' label: \(keeper.archiveStage)")
        #expect(!CatalogStorageTotalsCalculator.isManuallyDeleted(keeper), "the keeper vanished from the footer totals")
        #expect(pfActiveRecords(model.records).contains { $0 === keeper }, "the keeper left the catalog view")
        #expect(keeper.starRating == 3, "Rick's marks still carry")
    }

    // MARK: "Archived — what next?" prune fold, end to end

    @Test("PRUNE: trashing a labelled-deleted copy never labels the archive copy deleted or Trashed")
    func pruneFoldArchiveCopyStaysVisible() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("keeper_no_removal")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_keeper_a.mov"),
                                                       bytes: 32 * 1024, seed: 11)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1984")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA))
        MasterArchiveTestSupport.unlockTree(sb.root)

        let dupDir = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let a2 = dupDir.appendingPathComponent("test_keeper_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let recA2 = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1984")
        for r in [recA, recA2, archive] { r.contentHash = "v1:test-keeper-a" }
        model.records.append(recA2)
        await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: [recA.id, recA2.id]).flush?.value

        // An archive copy as a scan finds it: no stage yet. The copy being
        // trashed carries Migrate's old false label.
        archive.archiveStage = .none
        archive.lifecycleStage = .cataloged
        recA2.archiveStage = .manuallyDeleted

        let shown = await model.prunePlan(for: [recA.id, recA2.id], options: .init(), isOnline: { _ in true })
        let row = try #require(shown.families.first?.rows.first { $0.id == recA2.id && $0.checkable },
                               "fixture: the labelled copy is a checkable row — \(shown)")
        let out = await model.applyPrune(shown: shown, selected: [row.id], recordIDs: [recA.id, recA2.id],
                                         options: .init(), batchID: "keeper-test", mode: .permanent)
        #expect(out.trashed == 1, "\(out)")
        #expect(archive.archiveStage == .none, "the archive copy took 'deleted': \(archive.archiveStage)")
        #expect(archive.lifecycleStage == .cataloged, "the archive copy took the trashed copy's 'Trashed': \(archive.lifecycleStage)")
        #expect(pfActiveRecords(model.records).contains { $0 === archive })
    }

    // MARK: Repair confirm, end to end

    @Test("CONFIRM: a labelled-deleted original never hides its confirmed repair")
    func confirmRepairKeepsRepairVisible() {
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "tape.mov"; original.fullPath = "/Volumes/T/tape.mov"
        original.archiveStage = .manuallyDeleted
        original.lifecycleStage = .trashed
        let repair = VideoRecord()
        repair.filename = "tape_RepairedAudio.mov"; repair.fullPath = "/Volumes/T/tape_RepairedAudio.mov"
        repair.derivedFrom = original.id
        repair.derivationKind = "rebuildAudio"
        model.records = [original, repair]

        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.archiveStage == .none, "\(repair.archiveStage)")
        #expect(repair.lifecycleStage == .cataloged, "\(repair.lifecycleStage)")
        #expect(pfActiveRecords(model.records).contains { $0 === repair })
    }
}
