// StewardNestedDriveParityTests.swift
// Review C01-F1 (docs/reviews/cloud/C01-steward-and-device-id.md, branch
// cloud/C01): with NESTED scan targets ("/Users/u" and "/Users/u/Movies")
// the Reclaim set card used to put each file on the LONGEST scan root that
// holds it, while the Delete planner asks only whether the keeper sits
// inside the drive being cleaned. The card said "Left alone for now — the
// copy to keep is on another drive" for a copy that the run its own button
// starts would take.
//
// The pin: the card's standing for a copy is `.wouldBeChecked` EXACTLY when
// the copy is a target of `duplicateDeletionSelection(onVolume:)` on the
// card's drive — in either list order of the scan targets.
//
// Logic only: no disk (the selection and the builder read paths, never
// files). Isolation: each model has its own temp catalog directory.
// Scale / media matrix: N/A — the builder's 100k budget stays pinned by
// StewardScaleTests; no media is opened.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Steward C01-F1 — nested scan targets: the card says what the run does", .serialized)
@MainActor
struct StewardNestedDriveParityTests {

    private let outer = "/Users/u"
    private let inner = "/Users/u/Movies"

    private func isolatedModel() -> VideoScanModel {
        let model = VideoScanModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_steward_nested_\(UUID().uuidString.prefix(8))", isDirectory: true)
        model.catalogStore = CatalogStore(directory: dir)
        return model
    }

    private func record(_ path: String, group: UUID, _ disposition: DuplicateDisposition) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = 10
        r.partialMD5 = "m"
        r.durationSeconds = 61
        r.duplicateGroupID = group
        r.duplicateDisposition = disposition
        r.duplicateConfidence = .high
        return r
    }

    /// The pane's queue, built exactly as the model builds it (the scan
    /// targets in the model's own list order).
    private func queue(_ model: VideoScanModel) -> StewardQueue {
        let inputs = StewardCaseBuilder.project(model.records, protection: model.stewardProtectionRule())
        return StewardCaseBuilder.build(inputs: inputs, volumes: AnalyzeCoverageCalculator.volumeFacts(model.scanTargets),
                                        mountedRoots: ["/"], alsoCleanUpWorkingCopies: false)
    }

    private struct Rig {
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
    }

    /// Keeper under the inner target, a high-confidence extra copy directly
    /// under the outer one; "Also clean up working copies" OFF.
    private func rig(targets: [String], extraPairOnOuter: Bool = false) -> Rig {
        let model = isolatedModel()
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = false
        model.scanTargets = targets.map { CatalogScanTarget(searchPath: $0) }
        let g = UUID()
        let keeper = record("\(inner)/a.mov", group: g, .keep)
        let copy = record("\(outer)/b.mov", group: g, .extraCopy)
        var records = [keeper, copy]
        if extraPairOnOuter {
            // A second set wholly on the outer drive, so the Delete flow
            // offers that drive whatever the list order.
            let h = UUID()
            records += [record("\(outer)/c.mov", group: h, .keep), record("\(outer)/d.mov", group: h, .extraCopy)]
        }
        model.records = records
        return Rig(model: model, keeper: keeper, copy: copy)
    }

    private func standing(of copy: VideoRecord, in q: StewardQueue) throws -> (StewardCase, StewardCopyStanding) {
        let set = try #require(q.cases.first { $0.kind == .reclaimGroup && $0.copies.contains { $0.id == copy.id } })
        let row = try #require(set.copies.first { $0.id == copy.id })
        return (set, row.standing)
    }

    /// The finding's scenario as written: outer target listed first.
    @Test func outerFirstTheCardSaysTheCopyIsCheckedBecauseTheRunTakesIt() throws {
        let rig = rig(targets: [outer, inner])
        #expect(rig.model.volumesWithDeletableDuplicates().map(\.path).contains(outer),
                "fixture: the Delete flow offers the outer drive")
        let inRun = rig.model.duplicateDeletionSelection(onVolume: outer).targets.contains { $0.id == rig.copy.id }
        #expect(inRun, "fixture: the run on \(outer) takes the copy")

        let (set, standing) = try standing(of: rig.copy, in: queue(rig.model))
        #expect((standing == .wouldBeChecked) == inRun, "card says \(standing), the run on \(outer) \(inRun ? "takes" : "leaves") it")
        #expect(set.driveRoot == outer, "the card's button must start the run on the copy's drive")
        #expect(set.runRows.map(\.id) == [rig.copy.id] && set.runRows.first?.driveRoot == outer)
        #expect(set.copiesNeedingWorkingCopyMode == 0)
        #expect(set.actionableBytes == rig.copy.sizeBytes)
        // The drive card behind it counts the same copy.
        let drive = try #require(queue(rig.model).cases.first { $0.kind == .reclaimDrive && $0.driveRoot == outer })
        #expect(drive.recordIDs.contains(rig.copy.id))
    }

    /// The same files, inner target listed first. The card still states what
    /// a run on the copy's drive would do.
    @Test func innerFirstTheCardStillAgreesWithTheRunOnTheCopysDrive() throws {
        for extraPair in [false, true] {
            let rig = rig(targets: [inner, outer], extraPairOnOuter: extraPair)
            let inRun = rig.model.duplicateDeletionSelection(onVolume: outer).targets.contains { $0.id == rig.copy.id }
            #expect(inRun, "fixture: the run on \(outer) takes the copy (its keeper is inside \(outer))")
            let (set, standing) = try standing(of: rig.copy, in: queue(rig.model))
            #expect((standing == .wouldBeChecked) == inRun,
                    "extra pair \(extraPair): card says \(standing), the run on \(outer) \(inRun ? "takes" : "leaves") it")
            #expect(set.driveRoot == outer)
            if extraPair {
                #expect(rig.model.volumesWithDeletableDuplicates().map(\.path).contains(outer),
                        "fixture: the outer drive is offered, so the card's button runs there")
            }
        }
    }

    /// The parity, both orders, every copy: no second rule anywhere.
    @Test func everyCopysStandingEqualsSelectionMembershipInBothOrders() throws {
        for targets in [[outer, inner], [inner, outer]] {
            let rig = rig(targets: targets, extraPairOnOuter: true)
            let q = queue(rig.model)
            let drives = Set(q.cases.filter { $0.kind == .reclaimGroup }.flatMap(\.copies).map(\.driveRoot))
            var selected = Set<UUID>()
            for d in drives { selected.formUnion(rig.model.duplicateDeletionSelection(onVolume: d).targets.map(\.id)) }
            for set in q.cases where set.kind == .reclaimGroup {
                for row in set.copies where row.standing != .keeper {
                    #expect((row.standing == .wouldBeChecked) == selected.contains(row.id),
                            "\(targets): \(row.filename) on \(row.driveRoot) says \(row.standing)")
                }
            }
        }
    }

    /// Sensor: the builder asks the planner's own drive rule and same-drive
    /// predicate — it keeps no second copy of either.
    @Test func theBuilderUsesThePlannersDriveRuleNotItsOwn() throws {
        let builder = try SourceTree.appSource(named: "StewardCaseBuilder.swift")
        #expect(builder.contains("VideoScanModel.duplicateVolumeRoot("), "the builder's drive is not the planner's")
        #expect(builder.contains("VideoScanModel.duplicateKeeperIsOnVolume("), "the builder's same-drive test is not the planner's")
        #expect(!builder.contains("sorted { $0.count > $1.count }"), "longest-root-first is back in the builder")
        let planner = try SourceTree.appSource(named: "VideoScanModel+Duplicates.swift")
        #expect(planner.contains("Self.duplicateVolumeRoot(for: path, scanTargetPaths:"), "volumeRoot(for:) no longer delegates")
        #expect(planner.contains("if Self.duplicateKeeperIsOnVolume(keeperPath: keeper.fullPath, volumePath: volumePath) {"),
                "the selection no longer asks the shared predicate")
    }
}
